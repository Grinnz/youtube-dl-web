#!/usr/bin/env perl

use v5.20.0;
use Mojolicious::Lite -signatures;
use Mojo::Asset::File;
use Mojo::File 'tempdir', 'curfile', 'path';
use Mojo::SQLite;
use Mojo::URL;

use File::Spec;
use File::Temp ();
use IPC::Run3;
use MIME::Types;

my $types = MIME::Types->new;

plugin 'Config';
app->secrets(app->config->{secrets}) if defined app->config->{secrets};
app->log->with_roles('Mojo::Log::Role::Clearable')->path(app->config->{logfile}) if defined app->config->{logfile};

my $exec_path = app->config->{exec_path} // 'yt-dlp';

my $sqlite;
helper sqlite => sub { $sqlite //= Mojo::SQLite->new->from_filename(curfile->sibling('youtube-dl-web.sqlite')) };
plugin Minion => {SQLite => app->sqlite};

app->minion->add_task(download_video => sub ($job, $url, $options = {}) {
  my $tmp = $job->app->config->{tmpdir} // File::Spec->tmpdir;
  my $tempdir = tempdir(DIR => $tmp);
  my $template = "$tempdir/%(title)s-%(id)s.%(ext)s";
  my @args = ('-o', $template, '--quiet', '--restrict-filenames');
  unless ($options->{audio_only}) {
    my $videofilter = '';
    $videofilter .= "[height<=$options->{video_maxres}]" if ($options->{video_maxres} // 'best') ne 'best';
    $videofilter .= "[fps<=$options->{video_maxfps}]" if ($options->{video_maxfps} // 'best') ne 'best';
    my $format = $options->{video_format} // 'best';
    $format = $format eq 'best' ? "bestvideo$videofilter+bestaudio/best$videofilter" : "$format$videofilter";
    push @args, '--format', $format;
  }
  push @args, '--extract-audio', '--audio-format', $options->{audio_format} // 'best' if $options->{audio_only};
  run3 [$exec_path, @args, $url], undef, \my $stdout, \my $stderr;
  if ($?) {
    my $exitcode = $? >> 8;
    die "$exec_path $url failed with exit code $exitcode\nSTDOUT: $stdout\nSTDERR: $stderr\n";
  }
  my $filepath = $tempdir->list->first;
  die "No video downloaded by $exec_path $url\n" unless defined $filepath;
  my $basename = $filepath->basename;
  my $tempfile = File::Temp->new(DIR => $tmp, UNLINK => 0);
  $filepath->move_to($tempfile);
  $job->finish({tempfile => $tempfile, basename => $basename});
});

my %allowed_hosts = map { ($_ => 1) } qw(youtube.com www.youtube.com youtu.be twitch.tv www.twitch.tv clips.twitch.tv kick.com www.kick.com tiktok.com www.tiktok.com);

get '/' => 'form';
post '/' => sub ($c) {
  my $timeout = $c->app->config->{inactivity_timeout} // 600;
  $c->inactivity_timeout($timeout);

  my $url = $c->req->param('url');
  return $c->render('form', error_msg => 'No URL provided') unless length $url;
  $url = Mojo::URL->new($url);

  $url->scheme('https') unless length $url->scheme;
  return $c->render('form', error_msg => 'Invalid YouTube/Twitch URL') unless exists $allowed_hosts{lc($url->host // '')}
    and ($url->scheme eq 'http' or $url->scheme eq 'https');
  if (lc($url->host // '') =~ m!\byoutube.com\z!i and $url->path =~ m!^/shorts/([^/\s]+)!) {
    my $id = $1;
    $url->path('/watch');
    $url->query({v => $id});
  }

  my %options;
  $options{video_format} = $c->req->param('video-format');
  $options{video_maxres} = $c->req->param('video-maxres');
  $options{video_maxfps} = $c->req->param('video-maxfps');
  $options{audio_only} = $c->req->param('audio-only');
  $options{audio_format} = $c->req->param('audio-format');

  my $job_id = $c->minion->enqueue(download_video => [$url->to_string, \%options]);
  return $c->minion->result_p($job_id)->then(sub ($info) {
    my $result = $info->{result};
    unless (defined $result and defined $result->{tempfile}) {
      return $c->render('form', error_msg => 'Failed to download video');
    }
    my $tempfile = $result->{tempfile};
    my $basename = $result->{basename} // path($tempfile)->basename;
    $c->res->headers->content_disposition(qq{attachment; filename="$basename"});
    my $type = $types->mimeTypeOf($basename);
    my $content_type = defined $type ? $type->type : 'application/octet-stream';
    $c->res->headers->content_type($content_type);
    $c->reply->asset(Mojo::Asset::File->new(path => $tempfile)->cleanup(1));
  })->catch(sub ($info) {
    $c->log->error("Job $job_id failed: $info->{result}");
    $c->render('form', error_msg => 'Failed to download video', video_url => $url->to_string);
  });
} => 'download';

app->start;

__DATA__
@@ form.html.ep
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Video Downloader</title>
  <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.2.0/dist/css/bootstrap.min.css" rel="stylesheet" integrity="sha384-gH2yIJqKdNHPEq0n4Mqa/HGKIhSkIHeL5AyhkYV8i59U5AR6csBvApHHNl/vI1Bx" crossorigin="anonymous">
</head>
<body>
  <div class="container">
    <h2 class="mb-3">Video Downloader</h2>
    <form method="post">
      <div class="row mb-3">
        <label for="youtube-video-url" class="visually-hidden">Video URL</label>
        <div class="col-sm-6"><input type="text" class="form-control" id="youtube-video-url" name="url" <% if (defined stash('video_url')) { %>value="<%= stash('video_url') %>" <% } %>placeholder="Video URL"></div>
        <div class="col-sm-6"><select class="form-select" name="video-format" aria-label="Video format">
          <option value="best" selected>Best available video format</option>
          <option value="3gp">3gp</option>
          <option value="flv">flv</option>
          <option value="mp4">mp4</option>
          <option value="webm">webm</option>
        </select></div>
      </div>
      <div class="row mb-3">
        <div class="col-sm-6"><select class="form-select" name="video-maxres" aria-label="Max video resolution">
          <option value="best" selected>Best available video resolution</option>
          <option value="1080">1080p</option>
          <option value="720">720p</option>
          <option value="480">480p</option>
          <option value="360">360p</option>
          <option value="160">160p</option>
        </select></div>
        <div class="col-sm-6"><select class="form-select" name="video-maxfps" aria-label="Max video framerate">
          <option value="best" selected>Best available video framerate</option>
          <option value="60">60fps</option>
          <option value="30">30fps</option>
        </select></div>
      </div>
      <div class="row mb-3">
        <div class="col-sm-6">
          <div class="form-check">
            <input type="checkbox" class="form-check-input" id="youtube-video-audio-only" name="audio-only" value="1">
            <label for="youtube-video-audio-only" class="form-check-label">Audio Only</label>
          </div>
        </div>
        <div class="col-sm-6"><select class="form-select" name="audio-format" aria-label="Audio format">
          <option value="best" selected>Best available audio-only format</option>
          <option value="aac">aac</option>
          <option value="flac">flac</option>
          <option value="mp3">mp3</option>
          <option value="m4a">m4a</option>
          <option value="opus">opus</option>
          <option value="vorbis">vorbis</option>
          <option value="wav">wav</option>
        </select></div>
      </div>
      <div class="row mb-3 align-items-center">
        <div class="col-sm-1"><button type="submit" class="btn btn-primary">Download</button></div>
        <div class="col-sm-11"><span class="form-text">Please be patient and click download only once</span></div>
      </div>
      <div class="row mb-3">
      <% if (defined stash('error_msg')) { %>
        <span class="form-text text-danger">Error: <%= stash('error_msg') %></span>
      <% } else { %>
        <span class="form-text">Currently supported sites: YouTube, Twitch, Kick, TikTok</span>
      <% } %>
    </form>
  </div>
</body>
</html>
