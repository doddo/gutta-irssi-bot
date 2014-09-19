package Gutta::Plugins::Aop;
use warnings;
use parent 'Gutta::Plugin';
use strict;
use Gutta::Users;
use Gutta::Session;
use Gutta::Plugins::Auth;
use Data::Dumper;
use Switch;
use Getopt::Long qw(GetOptionsFromArray);


=head1 NAME

Gutta::Plugins::Aop

=head1 SYNOPSIS

Instruct bot to automatically handle op:ing nicks in channels.


=head1 DESCRIPTION

Provides support for having the bot automatically add nicks when joining and 
upon request.

=head1 aop

Handle aop:ing the incoming nick. aop:s get op.


  !aop [ info | [ add | del | modify ] NICK [ --channel C ] [ --lvl INT ] [ --mask M ]] 

=over 8

=item B<--channel>

What channel (if in a channel and ommitted, will assume it current channel)

=item B<--level>

The level is a number between 0-100. an aop can only add someone with less level
than itself has. A number above 1 means that the user will be oped, (but can't op)

=item B<--mask>

If the bot doesn't know what hostmask is associated with a nick, or the user
has not registered with register command and is identified, the mask must be 
manually sent to bot, with the --mask opt.

=back

=head1 op

used to give op to a user. 
If channel is omitted, it will assume current channel.
If is omitted, it will assume current channel.

  !op [ channel ] [ nick ]

=cut


my $log = Log::Log4perl->get_logger(__PACKAGE__);

sub _initialise
{
    # THe constructor in the parent class calls for this.
    my $self = shift;

    $self->{ session } = Gutta::Session->instance();
    $self->{ auth } = Gutta::Plugins::Auth->new();
    $self->{ users } = Gutta::Users->new();
    $self->_dbinit(); 
}


sub _setup_shema
{
    my $self = shift;

    my @queries  = (qq{
    CREATE TABLE IF NOT EXISTS aops (
               nick TEXT NOT NULL,
               mask TEXT NOT NULL,
            channel TEXT NOT NULL,
                lvl INTEGER,
    FOREIGN KEY(nick) REFERENCES users(nick),
      CONSTRAINT nick_per_chan UNIQUE (nick, channel)
    )});

    return @queries;
}

sub _event_handlers
{
    my $self = shift;
    return {

        'JOIN' => sub { $self->on_join(@_) },

    }
}

sub _commands
{
    my $self = shift;
    return {

        'aop' => sub { $self->process_cmd('aop', @_) },
         'op' => sub { $self->process_cmd('op', @_) },

    }
}

sub on_join
{
    my $self = shift;
    my $timestamp = shift;
    my $server = shift;
    my @payload = @_;    

    # they need someonw to aop
    $log->debug(Dumper(@payload));


    return "";
}

sub process_cmd
{
    my $self = shift;
    my $cmd = shift;
    my $server = shift;
    my $msg = shift;
    my $nick = shift;
    my $mask = shift;
    my $target = shift;
    my $rest_of_msg = shift;

    # some vars used ...
    my @responses;
    my @rest_of_msg;
    my $subcmd;
    my $target_nick;

    # Possble subcmd...
    if ($rest_of_msg)
    {
        ($subcmd, @rest_of_msg) = split(' ',$rest_of_msg);
        if (@rest_of_msg)
        {
            $target_nick = shift(@rest_of_msg);
        }
    }

    # OK do they want OP?
    if ($cmd eq 'op')
    {
        $self->__handle_op($nick, $mask, $target, @rest_of_msg);
    } elsif ($cmd eq 'aop'){
        if ($subcmd ~~ ["add", "del", "modify"])
        {
            push @responses, 
                $self->__nickmod($subcmd, $nick, $mask, $target, $target_nick, @rest_of_msg);
        }
    }

    return @responses;
}

sub __handle_op
{
    my $self = shift;
    my $nick = shift;
    my $mask = shift;
    my $target = shift;
    my @rest_of_msg = @_;

    # TODO

    return ;

}

sub __nickmod
{
    # Adds a nick to be automatically op:ed ...
    my $self = shift;
    my $subcmd = shift;
    my $nick = shift;
    my $mask = shift;
    my $target = shift;
    my $target_nick = shift;
    my @args = @_; 
    
    # Parse options...
    my $channel;
    my $level;
    my $target_mask;
    my $lvl;

    GetOptionsFromArray(\@args,
          'channel=s' => \$channel,
              'lvl=i' => \$lvl,
             'mask=s' => \$target_mask)
    or return "invalid options supplied";

    #
    # Has the user logged in to the system?
    #
    return "msg $target please identify first." unless $self->{ auth }->has_session($nick, $mask); 

    # Validate lvl if there is one.
    if ($lvl && ($lvl < 0 || $lvl > 100))
    {
        return "msg $target invalid lvl supplied:$lvl, should be between 0-100";
    }
    
    # Figure out who is the target
    unless ($target_nick)
    {
        return "msg $target missing target nick.";
    }

    # Figure out in what channel to target.
    if ($channel)
    {
        unless ($channel =~ m/^#+[a-z_0-9]{1,100}\b/i)
        {
            return "msg $target '$channel' does not validate as channel";
            $log->info("${nick} supplied an invalid channel '${channel}'...");
        }

    } elsif ($target =~ m/^#/){
        $log->debug("No --channel option supplied, falling back to $target...");
        $channel = $target;
    } else {
        # Bot does not know what channels this is about.
        return "msg $target unable to compute; don't know what --channel...";
    }

    # Figure out the mask of the target
    #
    # if $target_mask is passed as option, that is taken in preference of other
    # Methods...
    unless ($target_mask)
    {
        #
        # Check if there is any record stored about nick in running session...
        my $nickinfo = $self->{ session }->get_nickinfo($target_nick);

        if (exists $$nickinfo{ mask })
        {
            # Check if there's a hostmask entry for the nick..
            $target_mask = $$nickinfo{ mask };
            $log->debug("Found out that $target_nick has $target_mask");
        } else {
            return "msg $target I have no record about ${nick}'s hostmask...";
        }

    } else {
        # TODO validate user input hostmask.
    }

    # Check if $target_nick is registered ...
    unless (my $registered_user = $self->{ users }->get_user($target_nick))
    {
        return "msg $target tell $target_nick hen needs to register first ...";
    }


    $log->info(sprintf 'regged user %s requested regged user %s with hostmask %s to be %s',
                                    $nick, $target_nick, $target_mask, $subcmd);

    # Gather system information about $target_nick.
    $target_nickinfo = $self->__get_info_about_nick($target_nick, $target_mask);
    $source_nickinfo = $self->__get_info_about_nick($nick, $mask);
    # IS ADMIN?? $self->{ auth }->has_session($nick, $mask);   
        
    return;

}

sub __get_info_about_nick
{
    my $self = shift;
    my $nick = shift;
    my $mask = shift;

    my $dbh = $self->dbh();

    my $sth = $dbh->prepare(qq{ 
         SELECT nick,
                channel,
                mask,
                lvl
           FROM aops
          WHERE nick = ?
            AND mask = ?    
    });

    $sth->execute($nick, $mask);

    return $sth->fetchall_hashref(qw/nick/);

}

1;
