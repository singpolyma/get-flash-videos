# Part of get-flash-videos. See get_flash_videos for copyright.
package FlashVideo::Site::Youtube;

use strict;
use Encode;
use HTML::Entities;
use FlashVideo::Utils;
use URI::Escape;

my @formats = (
  { id => 37, resolution => [1920, 1080] },
  { id => 22, resolution => [1280, 720] },
  { id => 35, resolution => [854, 480] },
  { id => 34, resolution => [640, 360] },
  { id => 18, resolution => [480, 270] },
  { id => 5,  resolution => [400, 224] },
  { id => 17, resolution => [176, 144] },
  { id => 13, resolution => [176, 144] },
);

sub find_video {
  my ($self, $browser, $embed_url, $prefs) = @_;

  if($embed_url !~ m!youtube\.com/watch!) {
    $browser->get($embed_url);
    if ($browser->response->header('Location') =~ m!/swf/.*video_id=([^&]+)!
        || $embed_url =~ m!/v/([-_a-z0-9]+)!i
        || $browser->uri =~ m!v%3D([-_a-z0-9]+)!i) {
      # We ended up on a embedded SWF or other redirect page
      $embed_url = "http://www.youtube.com/watch?v=$1";
      $browser->get($embed_url);
    }
  }

  if (!$browser->success) {
    login($browser);
  }

  my $title = extract_info($browser)->{meta_title};
  if (!$title and
    $browser->content =~ /<div id="vidTitle">\s+<span ?>(.+?)<\/span>/ or
      $browser->content =~ /<div id="watch-vid-title">\s*<div ?>(.+?)<\/div>/) {
    $title = $1;
  }

  # If the page contains fmt_url_map, then process this. With this, we
  # don't require the 't' parameter.
  if ($browser->content =~ /["']fmt_url_map["']:\s{0,3}["']([^"']+)["']/) {
    debug "Using fmt_url_map method from page";
    return $self->download_fmt_map($prefs, $browser, $title, {}, uri_unescape($1));
  }

  my $video_id;
  if ($browser->content =~ /(?:var pageVideoId =|(?:CFG_)?VIDEO_ID'?\s*:)\s*'(.+?)'/
      || $embed_url =~ /v=([^&]+)/) {
    $video_id = $1;
  } else {
    check_die($browser, "Couldn't extract video ID");
  }

  my $t;
  if ($browser->content =~ /\W['"]?t['"]?: ?['"](.+?)['"]/) {
    $t = $1;
  }

  # Try to get Youtube's info for this video - needed for some types of
  # video.
  my $video_page_url = $browser->uri->as_string;

  if (my %info = get_youtube_video_info($browser->clone, $video_id, $video_page_url, $t)) {
    if($::opt{debug}) {
      require Data::Dumper;
      debug Data::Dumper::Dumper(\%info);
    }

    # Check for rtmp downloads
    if ($info{conn} =~ /^rtmp/) {
      # Get season and episode
      my ($season, $episode);

      if ($browser->content =~ m{<span[^>]*>Season ?(\d+)}i) {
        $season = $1;
      }

      if ($browser->content =~ m{<span[^>]*>[^<]+Ep\.?\w* ?(\d+)\W*\s*</span>}i) {
        $episode = $1;
      }

      if ($season and $episode) {
        $title .= sprintf " S%02dE%02d", $season, $episode;
      }

      # SWF verification, blah
      my $swf_url;
      if ($browser->content =~ /SWF_URL['"] ?: ?.{0,90}?(http:\/\/[^ ]+\.swf)/) {
        $swf_url = $1;
      } elsif($browser->content =~ /src=\\['"](.*?\.swf)/) {
        $swf_url = json_unescape($1);
      } else {
        die "Couldn't extract SWF URL";
      }

      my $rtmp_url = $info{conn};

      if($info{fmt_stream_map}) {
        my $fmt_stream_map = parse_youtube_format_url_map($info{fmt_stream_map}, 1);

        # Sort by quality...
        my $preferred_quality = $prefs->quality->choose(map { $fmt_stream_map->{$_->{id}}
            ? { resolution => $_->{resolution}, url => $fmt_stream_map->{$_->{id}} }
            : () } @formats);

        $rtmp_url = $preferred_quality->{url};
      }

      return {
        flv => title_to_filename($title),
        rtmp => $rtmp_url,
        swfhash($browser, $swf_url)
      };
    } elsif($info{fmt_url_map}) {
      debug "Using fmt_url_map method from info";
      return $self->download_fmt_map($prefs, $browser, $title, \%info, $info{fmt_url_map});
    }
  }

  # Try old get_video method, just incase.
  return download_get_video($browser, $prefs, $video_id, $title, $t);
}

sub download_fmt_map {
  my($self, $prefs, $browser, $title, $info, $fmt_map) = @_;

  my $fmt_url_map = parse_youtube_format_url_map($fmt_map);

  if (!$title and $browser->uri->as_string =~ m'/user/.*?#') {
    # This is a playlist and getting the video title without the ID is
    # practically impossible because multiple videos are referenced in the
    # page. However, the encrypted (apparently) video ID is included in the
    # URL.
    my $video_id = (split /\//, $browser->uri->fragment)[-1];

    my %info = get_youtube_video_info($browser->clone, $video_id);

    $title = $info->{title};
  }

  # Sort by quality...
  my $preferred_quality = $prefs->quality->choose(map { $fmt_url_map->{$_->{id}}
      ? { resolution => $_->{resolution}, url => $fmt_url_map->{$_->{id}} }
      : () } @formats);

  $browser->allow_redirects;

  return $preferred_quality->{url}, title_to_filename($title, "mp4");
}

sub download_get_video {
  my($browser, $prefs, $video_id, $title, $t) = @_;

  my $fetcher = sub {
    my($url, $filename) = @_;
    $url = url_exists($browser->clone, $url, 1);
    return $url, $filename if $url;
    return;
  };

  my @formats_to_try = @formats;

  while(my $fmt = $prefs->quality->choose(@formats_to_try)) {
    # Remove from the list
    @formats_to_try = grep { $_ != $fmt } @formats_to_try;

    # Try it..
    my @ret = $fetcher->("http://www.youtube.com/get_video?fmt=$fmt->{id}&video_id=$video_id&t=$t",
      title_to_filename($title, "mp4"));
    return @ret if @ret;
  }

  # Otherwise try without an ID
  my @ret = $fetcher->("http://www.youtube.com/get_video?video_id=$video_id&t=$t",
    title_to_filename($title));

  check_die($browser, "Unable to find video URL") unless @ret;

  $browser->allow_redirects;

  return @ret;
}

sub check_die {
  my($browser, $message) = @_;

  if($browser->content =~ m{class="yt-alert-content">([^<]+)}) {
    my $alert = $1;
    $alert =~ s/(^\s+|\s+$)//g;
    $message .= "\nYouTube: $alert";
    error $message;
    exit 1;
  } else {
    die "$message\n";
  }
}

sub login {
  my($browser) = @_;
  my $orig_uri = $browser->uri;

  if ($browser->response->code == 303 
    && $browser->response->header('Location') =~ m!/verify_age|/accounts/!) {
    # Lame age verification page - yes, we are grown up, please just give
    # us the video!
    my $confirmation_url = $browser->response->header('Location');
    print "Unfortunately, due to Youtube being lame, you have to have\n" .
    "an account to download this video.\n" .
    "Username (Google Account Email): ";
    chomp(my $username = <STDIN>);
    print "Ok, need your password (will be displayed): ";
    chomp(my $password = <STDIN>);
    unless ($username and $password) {
      error "You must supply Youtube account details.";
      exit 1;
    }

    $browser->get("http://www.youtube.com/login");
    if ($browser->response->code != 303) {
      die "Unexpected response from Youtube login.\n";
    }

    my $real_login_url = $browser->response->header('Location');
    $browser->get($real_login_url);

    $browser->form_with_fields('Email', 'Passwd');
    $browser->set_fields(Email  => $username,
      Passwd => $password);
    $browser->submit();

    if ($browser->content =~ /your login was incorrect/) {
      error "Couldn't log you in, check your username and password.";
      exit 1;
    } elsif ($browser->response->code == 302) {
      # expected, next step in login process
      my $check_cookie_url = $browser->response->header('Location');
      $browser->get($check_cookie_url);

      # and then another, html-only, non-http, redirection...
      if ($browser->content =~ /<meta.*"refresh".*?url=&#39;(.*?)&#39;"/i) {
        my $redirected = decode_entities($1);
        $browser->get($redirected);

        # If we weren't redirected to YouTube we might have a regional Google
        # site.
        if(URI->new($redirected)->host !~ /youtube/i) {
          if($browser->response->code == 302) {
            $browser->get($browser->response->header("Location"));
          } else {
            die "Did not find expected redirection";
          }
        }
      } else {
        die "Did not find expected redirection";
      }
    }
    else {
      die "Unexpected response during login";
    }

    # Now we go back to the video page, hopefully logged in...
    $browser->get($orig_uri);

    # the confirmation url will always fail to show the video these days
    # AND it'll fail to show the button apparently.
    if ($browser->response->code == 303) {
      # this account hasn't been enabled for grownup videos yet
      my $real_confirmation_url = $browser->response->header('Location');
      $browser->get($real_confirmation_url);
      if ($browser->form_with_fields('next_url', 'action_confirm')) {
        $browser->field('action_confirm' => 'Confirm Birth Date');
        $browser->click_button(name => "action_confirm");

        if ($browser->response->code != 303) {
          die "Unexpected response from Youtube";
        }
        $browser->get($browser->response->header('Location'));
      }
    }
  }
  else {
    # Lame Youtube redirection to uk.youtube.com and so on.
    if ($browser->response->code == 302) {
      $browser->get($browser->response->header('Location'));
    }

    if ($browser->response->code == 303) {
      debug "Video not available (303), trying " . $browser->response->header('Location');
      $browser->get($browser->response->header('Location'));
    }

    if (!$browser->success) {
      die "Couldn't download URL: " . $browser->response->status_line;
    }
  }
}

# Returns YouTube video information as key/value pairs for the specified
# video ID. The page that the video appears on can also be supplied. If not
# supplied, the function will create a suitable one.
sub get_youtube_video_info {
  my ($browser, $video_id, $url, $t) = @_;

  $url ||= "http://www.youtube.com/watch?v=$video_id";

  for my $el(qw(profilepage detailpage)) {
    my $video_info_url_template =
      "http://www.youtube.com/get_video_info?&video_id=%s&el=$el&ps=default&eurl=%s&hl=en_US&t=%s";

    my $video_info_url = sprintf $video_info_url_template,
      uri_escape($video_id), uri_escape($url), uri_escape($t);

    debug "get_youtube_video_info: $video_info_url";

    $browser->get($video_info_url);

    next unless $browser->success;

    return parse_youtube_video_info($browser->content);
  }

  error "Unable to get YouTube video information.";
}

# Decode form-encoded key-value pairs into a hash for convenience.
sub parse_youtube_video_info {
  my $raw_info = shift;

  my %video_info;

  foreach my $raw_pair (split /&/, $raw_info) {
    my ($key, $value) = split /=/, $raw_pair;
    $value = uri_unescape($value);
    $value =~ s/\+/ /g;

    $video_info{$key} = $value;
  }

  return %video_info;
}

# Some YouTube pages contain a "fmt_url_map", a mapping of quality codes
# (or "formats") to URLs from where the video can be downloaded. This
# function returns a hash reference keyed on the format number.
sub parse_youtube_format_url_map {
  my($raw_map, $param_idx) = @_;

  $param_idx = 0 unless defined $param_idx;

  my $map = {};

  # Now split on comma as the record is structured like
  # $quality|$url,$quality|$url
  foreach my $pair (split /,/, $raw_map) {
    my ($format, @params) = split /\|/, $pair;

    my $url = $params[$param_idx];

    # $url is double escaped so unescape again.
    $url = uri_unescape($url);

    $map->{$format} = $url;
  }
  
  return $map;
}

1;
