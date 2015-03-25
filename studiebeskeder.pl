#!/usr/bin/env perl
use 5.012;
use warnings;

use CHI;
use Digest::SHA qw/sha256_hex/;
use FindBin qw/$Bin/;
use HTML::Query qw/Query/;
use IO::All -utf8;
use Mojolicious::Lite;
use WWW::Mechanize;

# For how long should the list of news be cached?
use constant LIST_CACHE_DURATION => "3 hours";
# For how long should the text of news items be cached?
use constant ITEM_CACHE_DURATION => "12 hours";

my ($USERNAME, $PASSWORD) = io("$Bin/.ku_credentials")->slurp =~ /^([^:]+):(.*)$/;

die(<<END) unless $USERNAME;
    Place a file named '.ku_credentials' in the folder you run the program from.
    In it, put username:password for intranet.ku.dk login.
END


my $mech = WWW::Mechanize->new();
$mech->agent_alias('Windows Mozilla');

my $cache = CHI->new( driver => 'Memory', global => 1 );

my $log = Mojo::Log->new;

######
# Message fetching
######

sub getHTML {
    my $mech = shift;
    return $mech->response->decoded_content;
}


sub login {
    if ($mech->uri->as_string =~ qr/CookieAuth\.dll/) {
        # Login page; we need to log in.

        $mech->submit_form(
            with_fields => {
                username => $USERNAME,
                password => $PASSWORD
            },
        );
    }
}

sub messages {
    return $cache->compute("message_list", LIST_CACHE_DURATION, sub {
        $mech->get('https://intranet.ku.dk/nyheder/studiebeskeder/Sider/default.aspx');
        login();

        my $q = Query( text => $mech->response->decoded_content );
        my @news = $q->query('.NewsListing .NewsItem .NewsItemHeader')->get_elements;
        my $res = [];

        for my $item (@news) {
            $q = Query( $item );
            my $a = $q->query('.NewsItemTitle a')->first;
            my $title = $a->as_text;
            my $url = $a->attr('href');

            my $origin = $q->query('.NameDate')->first;
            my ($source, $date) = $origin->as_text =~ qr/[\s\n\r]*(.*?)[\s\n\r]*\|[\s\n\r]*(\d{2}-\d{2}-\d{4})/s;

            my $id = sha256_hex($url);

            push( @$res, {
                id      => $id,
                title   => $title,
                url     => "/message/$id",
                src_url => $url,
                source  => $source,
                date    => $date,
            } );
        }

        return $res;
    });
}

sub get_message {
    my $id = shift;
    return $cache->compute("message_$id", ITEM_CACHE_DURATION, sub {
        my $messages = messages();
        $messages = $messages->[0] if ref $messages->[0] eq 'ARRAY'; # wtf? why does this become double-nested?
        my ($message) = grep { ref $_ && ($_->{id} eq $id) } @$messages;

        return { error => "Unknown news item." } unless ($message);

        $mech->get($message->{src_url});
        login();

        my $q = Query( text => $mech->response->decoded_content );
        my $content = $q->query('.content')->first;
        my $res = { %$message };

        $res->{html} = $content->as_HTML;

        return $res;
    });
}

######
# HTTP routes
######

get '/' => sub {
    my $c = shift;

    $c->render(json => messages);
};

get '/message/:id' => [id => qr/[\da-f]+/i] => sub {
    my $c = shift;

    $c->render(json => get_message($c->stash('id')));
};

app->start;
