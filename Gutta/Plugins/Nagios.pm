package Gutta::Plugins::Nagios;
# does something with Nagios

use parent Gutta::Plugin;

use HTML::Strip;
use LWP::UserAgent;
use XML::FeedPP;
use MIME::Base64;
use JSON;
use strict;
use warnings;
use Data::Dumper;
use DateTime::Format::Strptime;
use Getopt::Long qw(GetOptionsFromArray);
use Switch;


=head1 NAME

Gutta::Plugins::Nagios


=head1 SYNOPSIS

Provides Nagios connection to gutta bot


=head1 DESCRIPTION

Add support to have gutta check the nagios rest api for hostgroup status and send any alarms encounterd into the target channel or channels.

say this:

 '!monitor config --username monitor --password monitor --nagios-server 192.168.60.182'

to configure a connection to monitor at 192.168.60.182 using username monitor and password monitor.

Then start using it:

!monitor hostgroup unix-servers --irc-server .* --to-channel #test123123

To add op5 irc monitoring for all servers in the unix-servers hostgroups on all servers, and send messages Crit, Warns and Clears to channel #test123123

Similarly

!unmoniutor hostgroup unix-servers

will remove monitoring for said server

Also you can do this:

!monitor host <hostid> --irc-server .* --to-channel #test123123

to add a single host.

=cut

my $log;

sub _initialise
{
    # called when plugin is istansiated
    my $self = shift;
    # The logger
    $log = Log::Log4perl->get_logger(__PACKAGE__);

    # initialise the database if need be.
    $self->_dbinit();

    # this one should start in its own thread.
    $self->{want_own_thread} = 1;
}

sub _commands
{
    my $self = shift;
    # the commands registered by this pluguin.
    #
    return {
        "monitor" => sub { $self->monitor(@_) },
      "unmonitor" => sub { $self->unmonitor(@_) },
    }
}

sub _setup_shema
{
    my $self = shift;

    my @queries  = (qq{
    CREATE TABLE IF NOT EXISTS monitor_hostgroups (
         irc_server TEXT NOT NULL,
            channel TEXT NOT NULL,
          hostgroup TEXT NOT NULL,
         last_check INTEGER DEFAULT 0,
      CONSTRAINT uniq_hgconf UNIQUE (irc_server, channel, hostgroup)
    )}, qq{
    CREATE TABLE IF NOT EXISTS monitor_hosts (
         irc_server TEXT NOT NULL,
            channel TEXT NOT NULL,
               host TEXT NOT NULL,
         last_check INTEGER DEFAULT 0,
      CONSTRAINT uniq_hconf UNIQUE (irc_server, channel, host)
    )}, qq{
    CREATE TABLE IF NOT EXISTS monitor_hoststatus (
          host_name TEXT PRIMARY KEY,
         hard_state INTEGER NOT NULL,
      plugin_output TEXT NOT NULL,
            address TEXT NOT NULL,
     from_hostgroup INTEGER NOT NULL
    )}, qq{
    CREATE TABLE IF NOT EXISTS monitor_servicedetail (
          host_name TEXT PRIMARY KEY,
            service TEXT NOT NULL,
              state INTEGER DEFAULT 0,
    FOREIGN KEY (host_name) REFERENCES monitor_hoststatus(host_name)
    )});

    return @queries;

}


sub monitor
{
    my $self = shift;
    my $server = shift;
    my $msg = shift;
    my $nick = shift;
    my $mask = shift;
    my $target = shift;
    my $rest_of_msg = shift;

    # they need something to monitor.
    return unless $rest_of_msg;

    my @irc_cmds;

    # get the commands.
    my ($subcmd, @values) = split(/\s+/, $rest_of_msg);

    switch (lc($subcmd))
    {
        case 'hostgroup' { @irc_cmds = $self->_monitor_hostgroup(@values) }
        case      'host' { @irc_cmds = $self->_monitor_host(@values) }
        case    'config' { @irc_cmds = $self->_monitor_config(@values) }
        case      'dump' { @irc_cmds = $self->_monitor_login(@values) }
        case   'runonce' { @irc_cmds = $self->_get_hostgroups(@values) }
    }

    return map { sprintf 'msg %s %s: %s', $target, $nick, $_ } @irc_cmds;
}

sub _monitor_hostgroup
{
    my $self = shift;
    my $hostgroup = shift;
    my @args = @_;

    my $server;
    my $channel;

    my $ret = GetOptionsFromArray(\@args,
        'irc-server=s' => \$server,
        'to-channel=s' => \$channel,
    ) or return "invalid options supplied.";

    $log->debug("setting up hostgroup config for $channel on server(s) mathcing $server\n");

    # get a db handle.
    my $dbh = $self->dbh();

    # Insert the stuff ino the database
    my $sth = $dbh->prepare(qq{INSERT OR REPLACE INTO monitor_hostgroups
        (hostgroup, irc_server, channel) VALUES(?,?,?)}) or return $dbh->errstr;

    # And DO it.
    $sth->execute($hostgroup, $server, $channel) or return $dbh->errstr;


    return "OK - added monitoring for hostgroup:[$hostgroup] on  channel:[$channel] for servers matching re:[$server]";
}

sub _monitor_config
{
    # Configure monitor, for example what nagios server is it?
    # who is the user and what is the password etc etc
    my $self = shift;
    my @args = @_;
    my %config;

    my $ret = GetOptionsFromArray(\@args, \%config,
           'username=s',
           'password=s',
     'check-interval=s',
      'nagios-server=s',
    ) or return "invalid options supplied:";

    while(my ($key, $value) = each %config)
    {
        $log->info("setting $key to $value for " . __PACKAGE__ . ".");
        $self->set_config($key, $value);
    }

    return 'got it.'
}

sub unmonitor
{
    my $self = shift;
    my $server = shift;
    my $msg = shift;
    my $nick = shift;
    my $mask = shift;
    my $target = shift;
    my $rest_of_msg = shift;

    # they need someonw to slap
    return unless $rest_of_msg;

    #TODO FIX THIS BORING.

    return;
}


sub _get_hostgroups
{
    my $self = shift;

    my $dbh = $self->dbh();

    # check what hostgroups are configured for monitoring.
    my $sth = $dbh->prepare(qq{SELECT DISTINCT hostgroup FROM monitor_hostgroups});
    $sth->execute();

    $log->debug(sprintf 'got %i hostgroups from db.', );

    # the hoststatus which've been fetched from the db
    my %db_hoststatus = $self->_db_get_hosts();

    # the same host status we just are about to get from the API.
    my %api_hoststatus;

    # Loop through all the configured hostgroups, and fetch node status for them.
    while ( my ($hostgroup) = $sth->fetchrow_array())
    {
        $log->debug("processing $hostgroup.....");

        my ($rval, $payload_or_message) = $self->__get_request(sprintf '/status/hostgroup/%s', $hostgroup);

        # do something with the payload.
        if ($rval)
        {
            my $payload = from_json($payload_or_message, { utf8 => 1 });

            my $members = @$payload{'members_with_state'};
            print Dumper(@$members);
            foreach my $member (@$members)
            {
                my ($hostname, $state, $has_been_checked) = @$member;
                $log->debug(sprintf 'got %s with state %i. been checked=%i', $hostname, $state, $has_been_checked);
                $api_hoststatus{$hostname} = $self->_api_get_host($hostname);
            }
        }
    }

    # OK so lets compare few things.
    foreach my $hostname (keys %api_hoststatus)
    {
        $log->debug("processing $hostname ...");
        # check if new host exists in the database or not.
        unless ($db_hoststatus{$hostname})
        {
            # TODO: handle the new host here.
            next;
        }
        foreach my $service (keys %{$api_hoststatus{$hostname}})
        {
            $log->debug("processing $service for $hostname");
            # check if the service is defined in the database or not.
            unless ($db_hoststatus{$hostname}{$service})
            {
                # TODO: handle the new service def for new host here.
                next;
            }
        
            # get the service state from API and database
            my $api_servicestate = $api_hoststatus{$hostname}{$service}{'state'};
            my $db_servicestate =  $db_hoststatus{$hostname}{$service}{'state'};
     

            if ($api_servicestate =! $db_servicestate)
            {
                # Here we got a diff between what nagios says and last "known" status (ie what it said last time
                # we checked, that's why this is an event we can send an alarm to or some such)
                #
                $log->debug(sprintf 'service "%s" for host "%s" have status from api %i and from db %i', $service, $hostname, $api_servicestate, $db_servicestate);

                

            }
        }

    }


    # OK lets update the database.
    #
    # First remove everyting (almost)!!
    $sth = $dbh->prepare(qq{
        DELETE FROM monitor_servicedetail
          WHERE NOT host_name IN (SELECT DISTINCT host FROM monitor_hosts)});

    $sth->execute();
    
    # TODO: Fix tomorrow.

    #$sth = $dbh->prepare(qq{
    #    INSERT INTO monitor_servicedetail host_name, service, state, has_been_checked
    #            VALUES (?,?,?,?)});

    


    return;
}

sub _api_get_host
{
    my $self = shift;
    my $host = shift;
    my %host_services;
    my $hostinfo; # the ref to json if succesful
    # make an API call to the monitor server to fetch info about the host.
    my ($rval, $payload_or_message) = $self->__get_request(sprintf '/status/host/%s', $host);

    if ($rval)
    {
        $hostinfo = from_json(($payload_or_message), { utf8 => 1 });
    } else {
        $log->warn("unable to pull data from $host: $payload_or_message");
        return;
    }

    my $services = @$hostinfo{'services_with_info'};
    $log->trace($services);
    foreach my $service (@$services)
    {
        $log->trace(Dumper($service));
        my ($servicename, $state, $has_been_checked, $msg) = @$service;
        %{$host_services{$servicename}} = (
                   'state' => $state,
                     'msg' => $msg,
               'host_name' => $host,
        'has_been_checked' => $has_been_checked,
        );
        $log->debug(sprintf 'service for "%s": "%s" with state %i: "%s"', $host, $servicename, $state, $msg);
    }

    return %host_services;
}


sub _db_get_hosts
{
    my $self = shift;
    my $dbh = $self->dbh();

    my $sth = $dbh->prepare('SELECT state, host_name, has_been_checked FROM monitor_servicedetail');

    $sth->execute();


    my $hosts = $sth->fetchall_hashref('host_name');

    $log->debug(Dumper($hosts));
    
}


sub __get_request
{
    my $self = shift;
    # the API path.
    my $path = shift;

    my $password = $self->get_config('password');
    my $username = $self->get_config('username');
    my $nagios_server = $self->get_config('nagios-server');
    my $apiurl = sprintf 'https://%s/api%s?format=json', $nagios_server, $path;

    my $ua = LWP::UserAgent->new;
    my $req = HTTP::Request->new(GET => $apiurl);

    if ($username && $password)
    {
        $log->info(sprintf 'setting authorization headers username=%s, password=[SECRET]', $username);
        $req->authorization_basic($username, $password);
    }

    # Do the download.
    my $response = $ua->request($req);

    # dome logging
    if ($response->is_success)
    {
        $log->debug("SUCCESSFULLY downloaded $apiurl");
        return 1, $response->decoded_content;
    } else {
        $log->warn(sprintf "ERROR on attempted download of %s:%s", $apiurl, $response->status_line);
        return 0, $response->status_line;
    }
}


1;