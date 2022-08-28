#!/usr/bin/env perl

use v5.20.0;
use Mojolicious::Lite -signatures;
use Mojo::Asset::File;
use Mojo::File 'tempdir', 'curfile', 'path';
use Mojo::SQLite;
use Mojo::URL;

use File::Temp ();
use IPC::Run3;
use MIME::Types;

my $types = MIME::Types->new;

plugin 'Config';
app->secrets(app->config->{secrets}) if defined app->config->{secrets};
app->log->with_roles('Mojo::Log::Role::Clearable')->path(app->config->{logfile}) if defined app->config->{logfile};

my $sqlite;
helper sqlite => sub { $sqlite //= Mojo::SQLite->new->from_filename(curfile->sibling('youtube-dl-web.sqlite')) };
plugin Minion => {SQLite => app->sqlite};

app->minion->add_task(download_video => sub ($job, $url, $options = {}) {
  my $tempdir = tempdir;
  my $template = "$tempdir/%(title)s-%(id)s.%(ext)s";
  my @args = ('-o', $template, '--quiet', '--restrict-filenames');
  push @args, '--extract-audio' if $options->{audio_only};
  run3 ['youtube-dl', @args, $url], undef, \my $stdout, \my $stderr;
  if ($?) {
    my $exitcode = $? >> 8;
    die "youtube-dl $url failed with exit code $exitcode\nSTDOUT: $stdout\nSTDERR: $stderr\n";
  }
  my $filepath = $tempdir->list->first;
  die "No video downloaded by youtube-dl $url\n" unless defined $filepath;
  my $basename = $filepath->basename;
  my $tempfile = File::Temp->new(UNLINK => 0);
  $filepath->move_to($tempfile);
  $job->finish({tempfile => $tempfile, basename => $basename});
});

get '/' => 'form';
post '/' => sub ($c) {
  $c->inactivity_timeout(1800);

  my $url = $c->req->param('url');
  return $c->render('form', error_msg => 'No URL provided') unless length $url;
  $url = Mojo::URL->new($url);

  my $host = lc($url->host) // '';
  return $c->render('form', error_msg => 'Invalid YouTube URL') unless $host eq 'youtube.com' or $host eq 'www.youtube.com' or $host eq 'youtu.be';
  if ($url->path =~ m!^/shorts/([^/\s]+)!) {
    my $id = $1;
    $url->host('www.youtube.com');
    $url->path('/watch');
    $url->query({v => $id});
  }

  my %options;
  $options{audio_only} = $c->req->param('audio-only');

  my $job_id = $c->minion->enqueue(download_video => [$url->to_string, \%options]);
  return $c->minion->result_p($job_id)->then(sub ($info) {
    my $result = $info->{result};
    unless (defined $result and defined $result->{tempfile}) {
      return $c->render('form', error_msg => 'Failed to download YouTube video');
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
    $c->render('form', error_msg => 'Failed to download YouTube video');
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
  <title>YouTube Downloader</title>
  <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.2.0/dist/css/bootstrap.min.css" rel="stylesheet" integrity="sha384-gH2yIJqKdNHPEq0n4Mqa/HGKIhSkIHeL5AyhkYV8i59U5AR6csBvApHHNl/vI1Bx" crossorigin="anonymous">
</head>
<body>
  <div class="container">
    <h2>YouTube Downloader</h2>
    <form method="post">
      <div class="row mb-3 align-items-center">
        <label for="youtube-video-url" class="visually-hidden">YouTube video URL</label>
        <div class="col-auto"><input type="text" class="form-control" id="youtube-video-url" name="url" placeholder="YouTube video URL"></div>
        <div class="col-auto formcheck">
          <input type="checkbox" class="form-check-input" id="youtube-video-audio-only" name="audio-only" value="1">
          <label for="youtube-video-audio-only" class="form-check-label">Audio Only</label>
        </div>
        <div class="col-auto"><button type="submit" class="btn btn-primary">Download</button></div>
        <div class="col-auto"><span class="form-text">Please be patient and click download only once</span></div>
      </div>
      <% if (defined stash('error_msg')) { %>
        <div class="row mb-3"><span class="form-text">Error: <%= stash('error_msg') %></span></div>
      <% } %>
    </form>
  </div>
</body>
</html>