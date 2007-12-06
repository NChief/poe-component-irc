# $Id: IRC.pm,v 1.4 2005/04/24 10:31:28 chris Exp $
#
# POE::Component::IRC, by Dennis Taylor <dennis@funkplanet.com>
# 
# Additional enhancements by Chris 'BinGOs' Williams.
#
# This module may be used, modified, and distributed under the same
# terms as Perl itself. Please see the license that came with your Perl
# distribution for details.
#

package POE::Component::IRC;

use 5.006;
use strict;
use warnings;
use POE qw( Wheel::SocketFactory Wheel::ReadWrite Driver::SysRW
	    Filter::Line Filter::Stream Filter::Stackable);
use POE::Filter::IRCD;
use POE::Filter::IRC::Compat;
use POE::Filter::CTCP;
use POE::Component::IRC::Plugin::Whois;
use POE::Component::IRC::Plugin::ISupport;
use POE::Component::IRC::Constants;
use POE::Component::IRC::Pipeline;
use POE::Component::IRC::Common qw(:ALL);
use Carp;
use Socket;
use File::Basename ();
use Symbol;
use vars qw($VERSION $REVISION $GOT_SSL $GOT_CLIENT_DNS);

# Load the plugin stuff
use POE::Component::IRC::Plugin qw( :ALL );

$VERSION = '5.37_02';
$REVISION = do {my@r=(q$Revision$=~/\d+/g);sprintf"%d"."%04d"x$#r,@r};

# BINGOS: I have bundled up all the stuff that needs changing for inherited classes
# 	  into _create. This gets called from 'spawn'.
#	  $self->{OBJECT_STATES_ARRAYREF} contains event mappings to methods that have
#		the same name, gets passed to POE::Session->create as $self => [ ];
#	  $self->{OBJECT_STATES_HASHREF} contains event mappings to methods, where the
#		event and the method have diferent names.
#	  $self->{IRC_CMDS} contains the traditional %irc_commands, mapping commands to events
#		and the priority that the command has.

my $GOT_SSL;
my $GOT_CLIENT_DNS;
my $GOT_SOCKET6;

# Check for SSL availability
BEGIN {
	$GOT_SSL = 0;
	eval {
		require POE::Component::SSLify;
		import POE::Component::SSLify qw( Client_SSLify );
		$GOT_SSL = 1;
	};
}

# Check for Client::DNS availability
BEGIN {
	$GOT_CLIENT_DNS = 0;
	eval {
		require POE::Component::Client::DNS;
		if ( $POE::Component::Client::DNS::VERSION >= 0.99 ) {
			$GOT_CLIENT_DNS = 1;
		}
	};
}

# Check if we have Socket6
BEGIN {
	$GOT_SOCKET6 = 0;
	eval {
		require Socket6;
		import Socket6;
		$GOT_SOCKET6 = 1;
	};
}

sub _create {
  my $self = shift;

  $self->{IRC_CMDS} =
  { 'rehash'    => [ PRI_HIGH,   'noargs',        ],
    'die'	=> [ PRI_HIGH,	 'noargs',	  ],
    'restart'   => [ PRI_HIGH,   'noargs',        ],
    'quit'      => [ PRI_NORMAL, 'oneoptarg',     ],
    'version'   => [ PRI_HIGH,   'oneoptarg',     ],
    'time'      => [ PRI_HIGH,   'oneoptarg',     ],
    'trace'     => [ PRI_HIGH,   'oneoptarg',     ],
    'admin'     => [ PRI_HIGH,   'oneoptarg',     ],
    'info'      => [ PRI_HIGH,   'oneoptarg',     ],
    'away'      => [ PRI_HIGH,   'oneoptarg',     ],
    'users'     => [ PRI_HIGH,   'oneoptarg',     ],
    'lusers'    => [ PRI_HIGH,   'oneoptarg',     ],
    'locops'    => [ PRI_HIGH,   'oneoptarg',     ],
    'operwall'  => [ PRI_HIGH,   'oneoptarg',     ],
    'wallops'   => [ PRI_HIGH,   'oneoptarg',     ],
    'motd'      => [ PRI_HIGH,   'oneoptarg',     ],
    'who'       => [ PRI_HIGH,   'oneoptarg',     ],
    'nick'      => [ PRI_HIGH,   'onlyonearg',    ],
    'oper'      => [ PRI_HIGH,   'onlytwoargs',   ],
    'invite'    => [ PRI_HIGH,   'onlytwoargs',   ],
    'squit'     => [ PRI_HIGH,   'onlytwoargs',   ],
    'kill'      => [ PRI_HIGH,   'onlytwoargs',   ],
    'privmsg'   => [ PRI_NORMAL, 'privandnotice', ],
    'privmsglo' => [ PRI_NORMAL+1, 'privandnotice', ],
    'privmsghi' => [ PRI_NORMAL-1, 'privandnotice', ],
    'notice'    => [ PRI_NORMAL, 'privandnotice', ],
    'noticelo'  => [ PRI_NORMAL+1, 'privandnotice', ],
    'noticehi'  => [ PRI_NORMAL-1, 'privandnotice', ],
    'join'      => [ PRI_HIGH,   'oneortwo',      ],
    'summon'    => [ PRI_HIGH,   'oneortwo',      ],
    'sconnect'  => [ PRI_HIGH,   'oneandtwoopt',  ],
    'whowas'    => [ PRI_HIGH,   'oneandtwoopt',  ],
    'stats'     => [ PRI_HIGH,   'spacesep',      ],
    'links'     => [ PRI_HIGH,   'spacesep',      ],
    'mode'      => [ PRI_HIGH,   'spacesep',      ],
    'part'      => [ PRI_HIGH,   'commasep',      ],
    'names'     => [ PRI_HIGH,   'commasep',      ],
    'list'      => [ PRI_HIGH,   'commasep',      ],
    'whois'     => [ PRI_HIGH,   'commasep',      ],
    'ctcp'      => [ PRI_HIGH,   'ctcp',          ],
    'ctcpreply' => [ PRI_HIGH,   'ctcp',          ],
    'ping'      => [ PRI_HIGH,   'oneortwo',      ],
    'pong'      => [ PRI_HIGH,   'oneortwo',      ],
  };

  my @event_map = map {($_, $self->{IRC_CMDS}->{$_}->[CMD_SUB])} keys %{ $self->{IRC_CMDS} };

  $self->{OBJECT_STATES_ARRAYREF} = [qw( _dcc_failed
				      _dcc_read
				      _dcc_timeout
				      _dcc_up
				      _delayed_cmd
				      _delay_remove
				      _parseline
				      __send_event
				      _sock_down
				      _sock_failed
				      _sock_up
				      _socks_proxy_connect
				      _socks_proxy_response
				      _start
				      _stop
				      debug
				      connect
				      dcc
				      dcc_accept
				      dcc_resume
				      dcc_chat
				      dcc_close
				      _resolve_addresses
				      _do_connect
				      _send_login
				      _got_dns_response
				      ison
				      kick
				      register
				      remove
				      shutdown
				      sl
				      sl_login
				      sl_high
                                      sl_delayed
				      sl_prioritized
				      topic
				      unregister
				      userhost )];

  $self->{OBJECT_STATES_HASHREF} = { @event_map, '_tryclose' => 'dcc_close', 'quote' => 'sl' };

  return 1;
}

# BINGOS: the component can now get its configuration from either spawn() or connect()
#	  _configure() deals with this.

sub _configure {
  my $self = shift;
  my $spawned = 0;
  my $args = shift;

  if ( defined ( $args ) and ref $args eq 'HASH' ) {
    my %arg = %$args;

    if (exists $arg{'flood'} and $arg{'flood'}) {
      $self->{'dont_flood'} = 0;
    } else {
      $self->{'dont_flood'} = 1 unless( defined ( $self->{'dont_flood'} ) and $self->{'dont_flood'} eq '0' );
    }

    if (exists $arg{'raw'} and $arg{'raw'}) {
      $self->{'raw_events'} = 1;
    } else {
      $self->{'raw_events'} = 0 unless ( $self->{'raw_events'} );
    }

    $self->{'password'} = $arg{'password'} if exists $arg{'password'};
    $self->{'localaddr'} = $arg{'localaddr'} if exists $arg{'localaddr'};
    $self->{'localport'} = $arg{'localport'} if exists $arg{'localport'};
    $self->{'nick'} = $arg{'nick'} if exists $arg{'nick'};
    $self->{'port'} = $arg{'port'} if exists $arg{'port'};
    $self->{'server'} = $arg{'server'} if exists $arg{'server'};
    $self->{'proxy'} = $arg{'proxy'} if exists $arg{'proxy'};
    $self->{'proxyport'} = $arg{'proxyport'} if exists $arg{'proxyport'};
    $self->{'ircname'} = $arg{'ircname'} if exists $arg{'ircname'};
    $self->{'username'} = $arg{'username'} if exists $arg{'username'};
    $self->{'NoDNS'} = $arg{'nodns'} if exists $arg{'nodns'};
    $self->{'nat_addr'} = $arg{'nataddr'} if exists $arg{'nataddr'};
    $self->{'user_bitmode'} = $arg{'bitmode'} if exists $arg{'bitmode'};
    $self->{'compress'} = $arg{'compress'} if exists $arg{'compress'};
    $self->{'socks_proxy'} = $arg{'socks_proxy'} if exists $arg{'socks_proxy'};
    $self->{'socks_port'} = $arg{'socks_port'} if exists $arg{'socks_port'};
    $self->{'socks_id'} = $arg{'socks_id'} if exists $arg{'socks_id'};
    $self->{'useipv6'} = $arg{'useipv6'} if exists $arg{'useipv6'};
    warn "'useipv6' specified, but Socket6 isn't loaded\n" 
	if $self->{'useipv6'} and !$GOT_SOCKET6;

    if (exists $arg{'debug'}) {
      $self->{'debug'} = $arg{'debug'};
      $self->{ircd_filter}->{DEBUG} = $arg{'debug'};
    }
    $self->{plugin_debug} = $arg{'plugin_debug'} if exists $arg{'plugin_debug'};
    my $dccport = delete $arg{'dccports'};
    $self->{'UseSSL'} = $arg{'usessl'} if exists $arg{'usessl'};

    warn "POE::Component::SSLify wasn\'t found, but you have specified 'usessl'\n"
	if $self->{'UseSSL'} and !$GOT_SSL;

    if ( defined ( $dccport ) and ref ( $dccport ) eq 'ARRAY' ) {
	  $self->{dcc_bind_port} = $dccport;
    }

    if ( $arg{'resolver'} and $arg{'resolver'}->isa("POE::Component::Client::DNS") ) {
	$self->{resolver} = $arg{'resolver'};
    }

    # This is a hack to make sure that the component doesn't die if no IRCServer is
    # specified as the result of being called from new() via spawn().

    $spawned = $arg{'CALLED_FROM_SPAWN'};
  }

  if ( $spawned and !$self->{NoDNS} and $GOT_CLIENT_DNS and !$self->{resolver} ) {
	$self->{resolver} = POE::Component::Client::DNS->spawn( Alias => "resolver" . $self->session_id() );
	$self->{mydns} = 1;
  }

  # Make sure that we have reasonable defaults for all the attributes.
  # The "IRC*" variables are ircII environment variables.
  $self->{'nick'} = $ENV{IRCNICK} || eval { scalar getpwuid($>) } ||
    $ENV{USER} || $ENV{LOGNAME} || "WankerBot"
      unless ($self->{'nick'});
  $self->{'username'} = eval { scalar getpwuid($>) } || $ENV{USER} ||
    $ENV{LOGNAME} || "foolio"
      unless ($self->{'username'});
  $self->{'ircname'} = $ENV{IRCNAME} || eval { (getpwuid $>)[6] } ||
    "Just Another Perl Hacker"
      unless ($self->{'ircname'});
  unless ($self->{'server'}) {
    die "No IRC server specified" unless $ENV{IRCSERVER} or $spawned;
    $self->{'server'} = $ENV{IRCSERVER};
  }
  $self->{'port'} = 6667 unless $self->{'port'};
  if ($self->{localaddr} and $self->{localport}) {
    $self->{localaddr} .= ":" . $self->{localport};
  }
}

# What happens when an attempted DCC connection fails.
sub _dcc_failed {
  my ($self, $operation, $errnum, $errstr, $id) =
    @_[OBJECT, ARG0 .. ARG3];

  unless (exists $self->{dcc}->{$id}) {
    if (exists $self->{wheelmap}->{$id}) {
      $id = $self->{wheelmap}->{$id};
    } else {
      warn "_dcc_failed: Unknown wheel ID: $id";
      return;
    }
  }

  # Reclaim our port if necessary.
  if ( $self->{dcc}->{$id}->{listener} and $self->{dcc_bind_port} and $self->{dcc}->{$id}->{listenport} ) {
	push ( @{ $self->{dcc_bind_port} }, $self->{dcc}->{$id}->{listenport} );
  }

  # Did the peer of a DCC GET connection close the socket after the file
  # transfer finished? If so, it's not really an error.
  if ($errnum == 0 and
  $self->{dcc}->{$id}->{type} eq "GET" and
  $self->{dcc}->{$id}->{done} >= $self->{dcc}->{$id}->{size}) {
    $self->_send_event( 'irc_dcc_done', $id,
    @{$self->{dcc}->{$id}}{ qw(nick type port file size done listenport clientaddr) } );
    close $self->{dcc}->{$id}->{fh};
    delete $self->{wheelmap}->{$self->{dcc}->{$id}->{wheel}->ID} if $self->{dcc}->{$id}->{wheel};
    delete $self->{dcc}->{$id}->{wheel};
    delete $self->{dcc}->{$id};
  }

  elsif ($errnum == 0 and
  $self->{dcc}->{$id}->{type} eq "CHAT") {
    $self->_send_event( 'irc_dcc_done', $id,
    @{$self->{dcc}->{$id}}{ qw(nick type port done listenport clientaddr) } );
    #close $self->{dcc}->{$id}->{fh};
    delete $self->{wheelmap}->{$self->{dcc}->{$id}->{wheel}->ID} if $self->{dcc}->{$id}->{wheel};
    delete $self->{dcc}->{$id}->{wheel};
    delete $self->{dcc}->{$id};
  }

  else {
    # In this case, something went wrong.
    if ($errnum == 0 and $self->{dcc}->{$id}->{type} eq "GET") {
      $errstr = "Aborted by sender";
    }
    else {
      if ($errstr) {
        $errstr = "$operation error $errnum: $errstr";
      }
      else {
        $errstr = "$operation error $errnum";
      }
    }
    $self->_send_event( 'irc_dcc_error', $id, $errstr,
		 @{$self->{dcc}->{$id}}{qw(nick type port file size done listenport clientaddr)} );
    # gotta close the file
    close $self->{dcc}->{$id}->{fh} if exists $self->{dcc}->{$id}->{fh};
    if (exists $self->{dcc}->{$id}->{wheel}) {
      delete $self->{wheelmap}->{$self->{dcc}->{$id}->{wheel}->ID};
      delete $self->{dcc}->{$id}->{wheel};
    }
    delete $self->{dcc}->{$id};
  }
  undef;
}

sub debug {
    my ( $self, $switch ) = @_[ OBJECT, ARG0 ];

    if ($switch eq "on") {
        $switch = 1;
    } elsif ($switch eq "off") {
        $switch = 0;
    }

    $self->{debug} = $switch;
    $self->{ircd_filter}->debug( $switch );
    $self->{ctcp_filter}->debug( $switch );
}


# Accept incoming data on a DCC socket.
sub _dcc_read {
  my ($self, $data, $id) = @_[OBJECT, ARG0, ARG1];

  $id = $self->{wheelmap}->{$id};

  if ($self->{dcc}->{$id}->{type} eq "GET") {

    # Acknowledge the received data.
    print {$self->{dcc}->{$id}->{fh}} $data;
    $self->{dcc}->{$id}->{done} += length $data;
    $self->{dcc}->{$id}->{wheel}->put( pack "N", $self->{dcc}->{$id}->{done} );

    # Send an event to let people know about the newly arrived data.
    $self->_send_event( 'irc_dcc_get', $id,
		 @{$self->{dcc}->{$id}}{ qw(nick port file size done listenport clientaddr) } );


  } elsif ($self->{dcc}->{$id}->{type} eq "SEND") {

    # Record the client's download progress.
    $self->{dcc}->{$id}->{done} = unpack "N", substr( $data, -4 );
    $self->_send_event( 'irc_dcc_send', $id,
		 @{$self->{dcc}->{$id}}{ qw(nick port file size done listenport clientaddr) } );

    # Are we done yet?
    if ($self->{dcc}->{$id}->{done} >= $self->{dcc}->{$id}->{size}) {

      # Reclaim our port if necessary.
      if ( $self->{dcc}->{$id}->{listener} and $self->{dcc_bind_port} and $self->{dcc}->{$id}->{listenport} ) {
        push ( @{ $self->{dcc_bind_port} }, $self->{dcc}->{$id}->{listenport} );
      }

      $self->_send_event( 'irc_dcc_done', $id,
		   @{$self->{dcc}->{$id}}{ qw(nick type port file size done listenport clientaddr) }
		 );
      delete $self->{wheelmap}->{$self->{dcc}->{$id}->{wheel}->ID};
      delete $self->{dcc}->{$id}->{wheel};
      delete $self->{dcc}->{$id};
      return;
    }

    # Send the next 'blocksize'-sized packet.
    read $self->{dcc}->{$id}->{fh}, $data, $self->{dcc}->{$id}->{blocksize};
    $self->{dcc}->{$id}->{wheel}->put( $data );

  }
  else {
    $self->_send_event( 'irc_dcc_' . lc $self->{dcc}->{$id}->{type},
		 $id, @{$self->{dcc}->{$id}}{'nick', 'port'}, $data );
  }
  undef;
}


# What happens when a DCC connection sits waiting for the other end to
# pick up the phone for too long.
sub _dcc_timeout {
  my ($kernel, $self, $id) = @_[KERNEL, OBJECT, ARG0];

  if (exists $self->{dcc}->{$id} and !$self->{dcc}->{$id}->{open}) {
    $kernel->yield( '_dcc_failed', 'connection', 0,
		    'DCC connection timed out', $id );
  }
  undef;
}


# This event occurs when a DCC connection is established.
sub _dcc_up {
  my ($kernel, $self, $sock, $addr, $port, $id) =
    @_[KERNEL, OBJECT, ARG0 .. ARG3];

  my $buf = '';

  # Monitor the new socket for incoming data and delete the listening socket.
  delete $self->{dcc}->{$id}->{factory};
  $self->{dcc}->{$id}->{addr} = $addr;
  $self->{dcc}->{$id}->{clientaddr} = inet_ntoa($addr);
  $self->{dcc}->{$id}->{port} = $port;
  $self->{dcc}->{$id}->{open} = 1;
  #bboett: -second step - the connection per DCC is opened, following the protocol we have to send a PRIVMSG User1 :DCC RESUME filename port position
  #set the correct filter....
  my $actualFilter = "";
  if($self->{dcc}->{$id}->{type} eq "CHAT" )
  {
    $actualFilter = POE::Filter::Line->new( Literal => "\012" );
  }# if("CHAT")
  else
  {
    #assume filetrasnfer
    $actualFilter = POE::Filter::Stream->new() ;
  }# else
  #->bboett
  $self->{dcc}->{$id}->{wheel} = POE::Wheel::ReadWrite->new(
      Handle => $sock,
      Driver => ($self->{dcc}->{$id}->{type} eq "GET" ?
		   POE::Driver::SysRW->new( BlockSize => INCOMING_BLOCKSIZE ) :
		   POE::Driver::SysRW->new() ),
#Filter => ($self->{dcc}->{$id}->{type} eq "CHAT" ?
#	       POE::Filter::Line->new( Literal => "\012" ) :
#	       POE::Filter::Stream->new() ),
      Filter => $actualFilter, #bboett
      InputEvent => '_dcc_read',
      ErrorEvent => '_dcc_failed',
  );
  $self->{wheelmap}->{$self->{dcc}->{$id}->{wheel}->ID} = $id;

  if ($self->{dcc}->{$id}->{'type'} eq 'GET') {
    my $handle = gensym();
    #bboett: added a check if the size is !=0 we suppose a resume
    if(-s $self->{dcc}->{$id}->{file})
    {
      unless (open $handle, ">>" . $self->{dcc}->{$id}->{file})
      {
	$kernel->yield( '_dcc_failed', 'open file', $! + 0, "$!", $id );
	return;
      }# unless (open $handle, ">>" . $self->{dcc}->{$id}->{file})
    }# if(-s $self->{dcc}->{$id}->{file})
    else
    {
      unless (open $handle, ">" . $self->{dcc}->{$id}->{file}) {
	$kernel->yield( '_dcc_failed', 'open file', $! + 0, "$!", $id );
	return;
      }
    }
    binmode $handle;

    # Store the filehandle with the rest of this connection's state.
    $self->{dcc}->{$id}->{'fh'} = $handle;

  }
  elsif ($self->{dcc}->{$id}->{type} eq 'SEND') {
    # Open up the file we're going to send.
    my $handle = gensym();
    unless (open $handle, "<" . $self->{dcc}->{$id}->{'file'}) {
      $kernel->yield( '_dcc_failed', 'open file', $! + 0, "$!", $id );
      return;
    }
    binmode $handle;

    # Send the first packet to get the ball rolling.
    read $handle, $buf, $self->{dcc}->{$id}->{'blocksize'};
    $self->{dcc}->{$id}->{wheel}->put( $buf );

    # Store the filehandle with the rest of this connection's state.
    $self->{dcc}->{$id}->{'fh'} = $handle;
  }

  # Tell any listening sessions that the connection is up.
  $self->_send_event( 'irc_dcc_start',
	       $id, @{$self->{dcc}->{$id}}{'nick', 'type', 'port'},
	       ($self->{dcc}->{$id}->{'type'} =~ /^(SEND|GET)$/ ?
		(@{$self->{dcc}->{$id}}{'file', 'size'}) : ()), @{$self->{dcc}->{$id}}{'listenport', 'clientaddr'} );
  undef;
}

# Parse a message from the IRC server and generate the appropriate
# event(s) for listening sessions.
sub _parseline {
  my ($session, $self, $ev) = @_[SESSION, OBJECT, ARG0];

  return unless $ev->{name};

  $self->_send_event( 'irc_raw' => $ev->{raw_line} ) if $self->{raw_events};

  # If its 001 event grab the server name and stuff it into {INFO}
  if ( $ev->{name} eq '001' ) {
	$self->{INFO}->{ServerName} = $ev->{args}->[0];
	$self->{RealNick} = ( split / /, $ev->{raw_line} )[2];
  }
  $ev->{name} = 'irc_' . $ev->{name};
  $self->_send_event( $ev->{name}, @{$ev->{args}} );

  if ($ev->{name} =~ /^irc_ctcp_(.+)$/) {
    $self->_send_event(irc_ctcp => $1 => @{$ev->{args}});
  }
  
  undef;
}

sub send_event {
  my $self = shift;
  $poe_kernel->call( $self->{SESSION_ID}, '__send_event', @_ );
  return 1;
}

# Hack to make plugin_add/del send events from OUR session
sub __send_event {
  my( $self, $event, @args ) = @_[ OBJECT, ARG0, ARG1 .. $#_ ];
  # Actually send the event...
  $self->_send_event( $event, @args );
  return 1;
}

# Sends an event to all interested sessions. This is a separate sub
# because I do it so much, but it's not an actual POE event because it
# doesn't need to be one and I don't need the overhead.
# Changed to a method by BinGOs, 21st January 2005.
# Amended by BinGOs (2nd February 2005) use call to send events to *our* session first.
sub _send_event  {
  my $self = shift;
  my ($event, @args) = @_;
  my $kernel = $POE::Kernel::poe_kernel;
  my $session = $kernel->get_active_session()->ID();
  my %sessions;

  # BINGOS:
  # I've moved these above the plugin system call to ensure that pesky plugins 
  # don't eat the events before *our* session can process them. *sigh*

  $sessions{$_} = $_ for (values %{$self->{events}->{'irc_all'}}, values %{$self->{events}->{$event}});

  # Make sure our session gets notified of any requested events before any other bugger
  $kernel->call( $session => $event => @args ) if delete $sessions{$session};

  my @extra_args;
  # Let the plugin system process this
  return 1 if $self->_plugin_process( 'SERVER', $event, \( @args ), \@extra_args ) == PCI_EAT_ALL;

  push @args, @extra_args if scalar @extra_args;

  # BINGOS:
  # We have a hack here, because the component used to send 'irc_connected' and
  # 'irc_disconnected' events to every registered session regardless of whether
  # that session had registered from them or not.
  if ( $event =~ /connected$/ or $event eq 'irc_shutdown' ) {
    $kernel->post( $self->{sessions}->{$_}->{'ref'},
		   $event, @args ) for keys %{ $self->{sessions} };
    return 1;
  }

  $kernel->post( $_ => $event => @args ) for values %sessions;
  undef;
}

sub _sock_flush {
  my ($kernel, $self) = @_[KERNEL, OBJECT];
  return unless $self->{_shutdown};
  delete $self->{'socket'};
  undef;
}

# Internal function called when a socket is closed.
sub _sock_down {
  my ($kernel, $self) = @_[KERNEL, OBJECT];

  # Destroy the RW wheel for the socket.
  delete $self->{'socket'};
  $self->{connected} = 0;

  # Stop any delayed sends.
  $self->{send_queue} = [ ];
  #$_[HEAP]->{send_queue} = $self->{send_queue};
  $self->{send_time}  = 0;
  $kernel->delay( sl_delayed => undef );

  # Reset the filters if necessary
  $self->_compress_uplink( 0 );
  $self->_compress_downlink( 0 );

  # post a 'irc_disconnected' to each session that cares
  $self->_send_event( 'irc_disconnected', $self->{server} );
  undef;
}

sub disconnect {
  $poe_kernel->post( $_[0]->session_id() => '_sock_down' );
}


# Internal function called when a socket fails to be properly opened.
sub _sock_failed {
  my ($self, $op, $errno, $errstr) = @_[OBJECT, ARG0..ARG2];

  delete $self->{'socketfactory'};
  $self->_send_event( 'irc_socketerr', "$op error $errno: $errstr" );
  undef;
}


# Internal function called when a connection is established.
sub _sock_up {
  my ($kernel, $self, $session, $socket) = @_[KERNEL, OBJECT, SESSION, ARG0];

  # We no longer need the SocketFactory wheel. Scrap it.
  delete $self->{'socketfactory'};

  # Remember what IP address we're connected through, for multihomed boxes.
  my $localaddr;
  if ( $GOT_SOCKET6 ) {
    eval {
	$localaddr = (unpack_sockaddr_in6( getsockname $socket ))[1];
    };
  }
  $localaddr = (unpack_sockaddr_in( getsockname $socket ))[1] unless $localaddr;
  $self->{'localaddr'} = $localaddr;

  if ( $self->{socks_proxy} ) {
    $self->{'socket'} = new POE::Wheel::ReadWrite
    ( Handle       => $socket,
      Driver       => POE::Driver::SysRW->new(),
      Filter	   => POE::Filter::Stream->new(),
      InputEvent   => '_socks_proxy_response',
      ErrorEvent   => '_sock_down',
      FlushedEvent => '_sock_flush',
    );
    unless ( $self->{'socket'} ) {
	$self->_send_event( 'irc_socketerr', "Couldn't create ReadWrite wheel for SOCKS socket" );
	return;
    }
    my $packet;
    if ( irc_ip_is_ipv4( $self->{server} ) ) {
      # SOCKS 4
      $packet = pack ('CCn', 4, 1, $self->{port}) .
	inet_aton($self->{server}) . ( $self->{socks_id} || '' ) . (pack 'x');
    }
    else {
      # SOCKS 4a
      $packet = pack ('CCn', 4, 1, $self->{port}) .
	inet_aton('0.0.0.1') . ( $self->{socks_id} || '' ) . (pack 'x') .
	$self->{server} . (pack 'x');
    }
    $self->{'socket'}->put( $packet );
    return;
  }

  #ssl!
  if ($GOT_SSL and $self->{'UseSSL'}) {
    eval {
      $socket = Client_SSLify( $socket );
    };
    if ($@) {
      #something didn't work
      warn "Couldn't use an SSL socket: $@ \n";
      $self->{'UseSSL'} = 0;
    }
  }

  if ( $self->{compress} ) {
	$self->_compress_uplink(1);
	$self->_compress_downlink(1);
  }
  # Create a new ReadWrite wheel for the connected socket.
  $self->{'socket'} = new POE::Wheel::ReadWrite
    ( Handle       => $socket,
      Driver       => POE::Driver::SysRW->new(),
      InputFilter  => $self->{srv_filter},
      OutputFilter => $self->{out_filter},
      InputEvent   => '_parseline',
      ErrorEvent   => '_sock_down',
      FlushedEvent => '_sock_flush',
    );

  if ($self->{'socket'}) {
    $self->{connected} = 1;
  } else {
    $self->_send_event( 'irc_socketerr', "Couldn't create ReadWrite wheel for IRC socket" );
  }

  # Post a 'irc_connected' event to each session that cares
  $self->_send_event( 'irc_connected', $self->{server} );

  # CONNECT if we're using a proxy
  if ($self->{proxy}) {
    
    #The original proxy code, AFAIK, did not actually work with an HTTP proxy.
    $kernel->call($session, 'sl_login', 'CONNECT ' . $self->{'server'} . ":" . $self->{'port'} . " HTTP/1.0\n\n");

    #KLUDGE: Also, the original proxy code assumes the connection is instantaneous
    #Since this is not always the case, mess with the queueing so that the sent text 
    #is delayed...
    $self->{send_time} = time() + 10;
  }
  $kernel->yield( '_send_login' );
  undef;
}

sub _socks_proxy_response {
  my ($kernel,$self,$session,$input) = @_[KERNEL,OBJECT,SESSION,ARG0];
  if ( length $input != 8 ) {
     $self->_send_event( 'irc_socks_failed', 'Mangled response from SOCKS proxy', $input );
     $self->disconnect();
     return;
  }
  my @resp = unpack 'CCnN', $input;
  unless ( scalar @resp == 4 and $resp[0] eq '0' and $resp[1] =~ /^(90|91|92|93)$/ ) {
     $self->_send_event( 'irc_socks_failed', 'Mangled response from SOCKS proxy', $input );
     $self->disconnect();
     return;
  }
  if ( $resp[1] eq '90' ) {
     $kernel->call( $session, '_socks_proxy_connect' );
     $self->{connected} = 1;
     $self->_send_event( 'irc_connected', $self->{server} );
     $kernel->yield( '_send_login' );
  }
  else {
     $self->_send_event( 'irc_socks_rejected', $resp[1], $self->{socks_proxy}, $self->{socks_port}, $self->{socks_id} );
     $self->disconnect();
  }
  undef;
}

sub _socks_proxy_connect {
  my ($kernel,$self) = @_[KERNEL,OBJECT];
  $self->{socket}->event( InputEvent => '_parseline' );
  $self->{socket}->set_input_filter( $self->{srv_filter} );
  $self->{socket}->set_output_filter( $self->{out_filter} );
  undef;
}

sub _send_login {
  my ($kernel,$self,$session) = @_[KERNEL,OBJECT,SESSION];

  # Now that we're connected, attempt to log into the server.
  if ($self->{password}) {
    $kernel->call( $session, 'sl_login', "PASS " . $self->{password} );
  }
  $kernel->call( $session, 'sl_login', "NICK " . $self->{nick} );
  $kernel->call( $session, 'sl_login', "USER " .
		 join( ' ', $self->{username},
		       ($self->{'user_bitmode'} ? $self->{'user_bitmode'} : 0),
		       '*',
		       ':' . $self->{ircname} ));

  # If we have queued data waiting, its flush loop has stopped
  # while we were disconnected.  Start that up again.
  $kernel->delay(sl_delayed => 0);
  undef;
}


# Set up the component's IRC session.
sub _start {
  my ($kernel, $session, $sender, $self, $alias) = @_[KERNEL, SESSION, SENDER, OBJECT, ARG0];
  my @options = @_[ARG1 .. $#_];

  $kernel->state( '_poco_irc_sig_register' => $self );
  $kernel->sig( POCOIRC_REGISTER => '_poco_irc_sig_register' );
  $kernel->state( '_poco_irc_sig_shutdown' => $self );
  $kernel->sig( POCOIRC_SHUTDOWN => '_poco_irc_sig_shutdown' );

  # Send queue is used to hold pending lines so we don't flood off.
  # The count is used to track the number of lines sent at any time.
  $self->{send_queue} = [ ];
  $self->{send_time}  = 0;

  $session->option( @options ) if @options;

  if ( $alias ) {
     $kernel->alias_set($alias);
     $self->{alias} = $alias;
  } else {
     $kernel->alias_set("$self");
     $self->{alias} = "$self";
  }

  $self->{ircd_filter} = POE::Filter::IRCD->new( DEBUG => $self->{debug} );
  $self->{ircd_compat} = POE::Filter::IRC::Compat->new( DEBUG => $self->{debug} );
  $self->{ctcp_filter} = POE::Filter::CTCP->new();
  my $filters = [
		   POE::Filter::Line->new( InputRegexp => '\015?\012',
					    OutputLiteral => "\015\012" ),
		   $self->{ircd_filter},
		   $self->{ircd_compat},
		];
		   
  $self->{srv_filter} = POE::Filter::Stackable->new( Filters => $filters );
  $self->{out_filter} = POE::Filter::Stackable->new( Filters => [ POE::Filter::Line->new( OutputLiteral => "\015\012" ) ] );

  eval{ 
	require POE::Filter::Zlib::Stream;
  };
  $self->{can_do_zlib} = 1 unless $@;
  $self->{SESSION_ID} = $session->ID();

  # Plugin 'irc_whois' and 'irc_whowas' support
  $self->plugin_add ( 'Whois' . $self->{SESSION_ID}, POE::Component::IRC::Plugin::Whois->new() );

  $self->{isupport} = POE::Component::IRC::Plugin::ISupport->new();
  $self->plugin_add( 'ISupport' . $self->{SESSION_ID}, $self->{isupport} );

  if ( $kernel != $sender ) {
    my $sender_id = $sender->ID;
    $self->{events}->{'irc_all'}->{$sender_id} = $sender_id;
    $self->{sessions}->{$sender_id}->{'ref'} = $sender_id;
    $self->{sessions}->{$sender_id}->{refcnt}++;
    $kernel->refcount_increment($sender_id, PCI_REFCOUNT_TAG);
    $kernel->post( $sender, 'irc_registered', $self );
  }

  return 1;
}


# Destroy ourselves when asked politely.
sub _stop {
  my ($kernel, $self, $quitmsg) = @_[KERNEL, OBJECT, ARG0];

  if ($self->{connected}) {
    $kernel->call( $_[SESSION], 'quit', $quitmsg );
    $kernel->call( $_[SESSION], 'shutdown', $quitmsg );
  }
  undef;
}


# The handler for commands which have N arguments, separated by commas.
sub commasep {
  my ($kernel, $self, $state) = @_[KERNEL, OBJECT, STATE];
  my @args = @_[ARG0 .. $#_]; my $args;

  SWITCH: {
    if ( $state eq 'whois' and scalar @args > 1 ) {
	$args = shift @args;
	$args .= ' ' . join ',', @args;
	last SWITCH;
    }
    $args = join ',', @args;
  }

  my $pri = $self->{IRC_CMDS}->{$state}->[CMD_PRI];

  $state = uc $state;
  $state .= " $args" if defined $args;
  $kernel->yield( 'sl_prioritized', $pri, $state );
  undef;
}


# Get variables in order for openning a connection
sub connect {
  my ($kernel, $self, $session, $sender, $args) = @_[KERNEL, OBJECT, SESSION, SENDER, ARG0];
  my %arg;

  if ($args) {
    SWITCH: {
      if (ref $args eq 'ARRAY') {
        %arg = @$args;
	last SWITCH;
      }
      if (ref $args eq 'HASH') {
        %arg = %$args;
	last SWITCH;
      }
    }
  }

  $arg{ lc $_ } = delete $arg{$_} for keys %arg;

  $self->_configure( \%arg );

  if ( $self->{resolver} and $self->{res_addresses} and scalar @{ $self->{res_addresses} } ) {
	push @{ $self->{res_addresses} }, $self->{'server'};
	$self->{'server'} = shift @{ $self->{res_addresses} };
  }

  # try and use non-blocking resolver if needed
  if ( $self->{resolver} && !irc_ip_get_version( $self->{'server'} ) && !$self->{'NoDNS'} ) {
    $kernel->yield( _resolve_addresses => $self->{'server'}, ( $self->{useipv6} && $GOT_SOCKET6 ? 'AAAA' : 'A' ) );
  } 
  else {
    $kernel->yield("_do_connect");
  }

  $self->{RealNick} = $self->{nick};
  undef;
}

sub _resolve_addresses {
  my ($kernel,$self,$hostname,$type) = @_[KERNEL,OBJECT,ARG0..ARG1];
  my $response = $self->{resolver}->resolve( 
	event => '_got_dns_response', 
	host => $hostname,
	type => $type, 
	context => { }, 
  );
  $kernel->yield( _got_dns_response => $response ) if $response;
  return;
}

# open the connection
sub _do_connect {
  my ($kernel,$self,$session) = @_[KERNEL,OBJECT,SESSION];
  my $domain = AF_INET;

  # Disconnect if we're already logged into a server.
  $kernel->call( $session, 'quit' ) if $self->{'socket'};

  $self->{socks_port} = 1080 if $self->{socks_proxy} and !$self->{socks_port};

  if ( $self->{socks_proxy} and irc_ip_is_ipv6( $self->{socks_proxy} ) ) {
	unless ( $GOT_SOCKET6 ) {
	   warn "IPv6 address specified for 'socks_proxy' but Socket6 not found\n";
	   return;
	}
	$domain = AF_INET6;
  }
  elsif ( $self->{proxy} and irc_ip_is_ipv6( $self->{proxy} ) ) {
	unless ( $GOT_SOCKET6 ) {
	   warn "IPv6 address specified for 'proxy' but Socket6 not found\n";
	   return;
	}
	$domain = AF_INET6;
  }
  elsif ( $self->{server} and irc_ip_is_ipv6( $self->{server} ) ) {
	unless ( $GOT_SOCKET6 ) {
	   warn "IPv6 address specified for 'server' but Socket6 not found\n";
	   return;
	}
	$domain = AF_INET6;
  }
  elsif ( $self->{localaddr} and irc_ip_is_ipv6( $self->{localaddr} ) ) {
	unless ( $GOT_SOCKET6 ) {
	   warn "IPv6 address specified for 'localaddr' but Socket6 not found\n";
	   return;
	}
	$domain = AF_INET6;
  }
  elsif ( $self->{useipv6} and $GOT_SOCKET6 ) {
  	$domain = AF_INET6;
  }

  $self->{'socketfactory'} =
  POE::Wheel::SocketFactory->new( 
	SocketDomain   => $domain,
	SocketType     => SOCK_STREAM,
	SocketProtocol => 'tcp',
	RemoteAddress  => $self->{socks_proxy} || $self->{'proxy'} || $self->{'server'},
	RemotePort     => $self->{socks_port} || $self->{'proxyport'} || $self->{'port'},
	SuccessEvent   => '_sock_up',
	FailureEvent   => '_sock_failed',
	($self->{localaddr} ?
	       (BindAddress => $self->{localaddr}) : ()),
  );
  undef;
}

# got response from POE::Component::Client::DNS
sub _got_dns_response {
  my ($kernel,$self) = @_[KERNEL,OBJECT];
  my $type = uc $_[ARG0]->{type};
  my $net_dns_packet = $_[ARG0]->{response};
  my $net_dns_errorstring = $_[ARG0]->{error};
  $self->{res_addresses} = [ ];

  unless(defined $net_dns_packet) {
    $self->_send_event( 'irc_socketerr', $net_dns_errorstring );
    return;
  }

  my @net_dns_answers = $net_dns_packet->answer;

  foreach my $net_dns_answer (@net_dns_answers) {
    next unless $net_dns_answer->type =~ /^A/;
    push @{ $self->{res_addresses} }, $net_dns_answer->rdatastr;
  }

  if ( !scalar @{ $self->{res_addresses} } and $type eq 'AAAA') {
    $kernel->yield( _resolve_addresses => $self->{'server'}, 'A' );
    return;
  }

  unless ( scalar @{ $self->{res_addresses} } ) {
    $self->_send_event( 'irc_socketerr', "Unable to resolve $self->{'server'}");
    return;
  }

  if ( my $address = shift @{ $self->{res_addresses} } ) {
    $self->{'server'} = $address;
    $kernel->yield("_do_connect");
    return;
  }

  $self->_send_event( 'irc_socketerr', "Unable to resolve $self->{'server'}");
  undef;
}

# Send a CTCP query or reply, with the same syntax as a PRIVMSG event.
sub ctcp {
  my ($kernel, $state, $self, $to) = @_[KERNEL, STATE, OBJECT, ARG0];
  my $message = join ' ', @_[ARG1 .. $#_];

  unless (defined $to and defined $message) {
    warn "The POE::Component::IRC event \"$state\" requires two arguments";
    return;
  }

  # CTCP-quote the message text.
  ($message) = @{$self->{ctcp_filter}->put([ $message ])};

  # Should we send this as a CTCP request or reply?
  $state = $state eq 'ctcpreply' ? 'notice' : 'privmsg';

  $kernel->yield( $state, $to, $message );
  undef;
}


# Attempt to initiate a DCC SEND or CHAT connection with another person.
sub dcc {
  my ($kernel, $self, $nick, $type, $file, $blocksize, $timeout) =
    @_[KERNEL, OBJECT, ARG0 .. ARG4];
  my ($factory, $port, $myaddr, $size);

  unless ($type) {
    warn "The POE::Component::IRC event \"dcc\" requires at least two arguments";
    return;
  }

  $type = uc $type;

  # Let the plugin system process this
  if ( $self->_plugin_process( 'USER', 'DCC', \$nick, \$type, \$file, \$blocksize ) == PCI_EAT_ALL ) {
  	return 1;
  }

  if ($type eq 'CHAT') {
    $file = 'chat';		# As per the semi-specification

  } elsif ($type eq 'SEND') {
    unless ($file) {
      warn "The POE::Component::IRC event \"dcc\" requires three arguments for a SEND";
      return;
    }
    $size = (stat $file)[7];
    unless (defined $size) {
      $self->_send_event( 'irc_dcc_error', 0,
		   "Couldn't get ${file}'s size: $!", $nick, $type, 0, $file );
    }
  }

  if ($self->{localaddr} and $self->{localaddr} =~ tr/a-zA-Z.//) {
    $self->{localaddr} = inet_aton( $self->{localaddr} );
  }

  my $bindport = 0;

  if ( $self->{dcc_bind_port} ) {
	$bindport = shift @{ $self->{dcc_bind_port} };
	unless ($bindport) {
		warn "dcc: Can't allocate listen port for DCC $type";
		return;
	}
  }

  $factory = POE::Wheel::SocketFactory->new(
      BindAddress  => $self->{localaddr} || INADDR_ANY,
      BindPort     => $bindport,
      SuccessEvent => '_dcc_up',
      FailureEvent => '_dcc_failed',
      Reuse        => 'yes',
  );
  ($port, $myaddr) = unpack_sockaddr_in( $factory->getsockname() );
  $myaddr = inet_aton( $self->{nat_addr} ) if $self->{nat_addr};
  unless ($myaddr) {
    warn "dcc: Can't determine our IP address! ($!)";
    return;
  }
  $myaddr = unpack "N", $myaddr;

  # Tell the other end that we're waiting for them to connect.
  my $basename = File::Basename::basename( $file );
  $basename =~ s/\s/_/g;

  $kernel->yield( 'ctcp', $nick, "DCC $type $basename $myaddr $port"
		  . ($size ? " $size" : "") );

  # Store the state for this connection.
  $self->{dcc}->{$factory->ID} = { open => undef,
				   nick => $nick,
				   type => $type,
				   file => $file,
				   size => $size,
				   port => $port,
				   addr => $myaddr,
				   done => 0,
				   blocksize => ($blocksize || BLOCKSIZE),
				   listener => 1,
				   factory => $factory,

				   listenport => $bindport,
				   clientaddr => $myaddr,
				 };
  $kernel->alarm( '_dcc_timeout', time() + ($timeout || DCC_TIMEOUT), $factory->ID );
  undef;
}


# Accepts a proposed DCC connection to another client. See '_dcc_up' for
# the rest of the logic for this.
sub dcc_accept {
  my ($kernel, $self, $cookie, $myfile) = @_[KERNEL, OBJECT, ARG0, ARG1];

  # Let the plugin system process this
  if ( $self->_plugin_process( 'USER', 'DCC_ACCEPT', \$cookie, \$myfile ) == PCI_EAT_ALL ) {
  	return 1;
  }

  if ($cookie->{type} eq 'SEND' || $cookie->{type} eq 'ACCEPT')
  {
    $cookie->{type} = 'GET';
    $cookie->{file} = $myfile if defined $myfile;   # filename override
  }

  my $factory = POE::Wheel::SocketFactory->new(
      RemoteAddress => $cookie->{addr},
      RemotePort    => $cookie->{port},
      SuccessEvent  => '_dcc_up',
      FailureEvent  => '_dcc_failed',
  );
  $self->{dcc}->{$factory->ID} = $cookie;
  $self->{dcc}->{$factory->ID}->{factory} = $factory;
}
# bboett - first step - the user asks for a resume:
# tries to resume a previous dcc transfer. See '_dcc_up' for
# the rest of the logic for this.
sub dcc_resume
{
  my ($kernel, $self, $cookie) = @_[KERNEL, OBJECT, ARG0 .. ARG2];

  # Let the plugin system process this
  if ( $self->_plugin_process( 'USER', 'DCC_RESUME', \$cookie ) == PCI_EAT_ALL ) {
  	return 1;
  }

  if ($cookie->{type} eq 'SEND') {
    $cookie->{type} = 'RESUME';

    my $myfile = $cookie->{tmpfile};
    if($cookie->{tmpfile})
    {
      my $mysize = -s $cookie->{tmpfile};
      my $fraction = $mysize % INCOMING_BLOCKSIZE;
      print("DCC RESUME org size $mysize frac= $fraction\n");
      $mysize -= $fraction;
      $cookie->{resumesize} = $mysize;
      # we need to truncate the whole thing, adjust the size we are
      # requesting to the size we will truncate the file to
      if(open(FILE,">>".$myfile))
      {
	if(truncate(FILE,$mysize))
	{
	  print("Success truncating file to size=$mysize\n");
	}
	my ($nick,$name,$host) = ( $cookie->{nick} =~ /(\S+)!(\S+)@(\S+)/);
	close(FILE);

	my $message = 'DCC RESUME '.$cookie->{file}." ".$cookie->{port}." ".$mysize.'';
	my $state = 'PRIVMSG';
	my $pri = $self->{IRC_CMDS}->{$state}->[CMD_PRI];

	$state .= " $nick :$message";
	$kernel->yield( 'sl_prioritized', $pri, $state );
      }# if(open(FILE,">>".$myfile))
    }# if($mysize)
  }
  undef;
}# sub dcc_resume


# Send data over a DCC CHAT connection.
sub dcc_chat {
  my ($kernel, $self, $id, @data) = @_[KERNEL, OBJECT, ARG0, ARG1 .. $#_];

  unless (exists $self->{dcc}->{$id}) {
    warn "dcc_chat: Unknown wheel ID: $id";
    return;
  }
  unless (exists $self->{dcc}->{$id}->{wheel}) {
    warn "dcc_chat: No DCC wheel for $id!";
    return;
  }
  unless ($self->{dcc}->{$id}->{type} eq "CHAT") {
    warn "dcc_chat: $id isn't a DCC CHAT connection!";
    return;
  }

  # Let the plugin system process this
  if ( $self->_plugin_process( 'USER', 'DCC_CHAT', \$id, \( @data ) ) == PCI_EAT_ALL ) {
  	return 1;
  }

  $self->{dcc}->{$id}->{wheel}->put( join "\n", @data );
  undef;
}


# Terminate a DCC connection manually.
sub dcc_close {
  my ($kernel, $self, $id) = @_[KERNEL, OBJECT, ARG0];

  if ($self->{dcc}->{$id}->{wheel}->get_driver_out_octets()) {
    $kernel->delay( _tryclose => .2 => @_[ARG0..$#_] );
    return;
  }

  # Let the plugin system process this
  if ( $self->_plugin_process( 'USER', 'DCC_CLOSE', \$id ) == PCI_EAT_ALL ) {
  	return 1;
  }

  $self->_send_event( 'irc_dcc_done', $id,
	       @{$self->{dcc}->{$id}}{ qw(nick type port file size done listenport clientaddr) } );

  # Reclaim our port if necessary.
  if ( $self->{dcc}->{$id}->{listener} and $self->{dcc_bind_port} and $self->{dcc}->{$id}->{listenport} ) {
	push ( @{ $self->{dcc_bind_port} }, $self->{dcc}->{$id}->{listenport} );
  }

  if (exists $self->{dcc}->{$id}->{wheel}) {
    delete $self->{wheelmap}->{$self->{dcc}->{$id}->{wheel}->ID};
    delete $self->{dcc}->{$id}->{wheel};
  }
  delete $self->{dcc}->{$id};
  undef;
}



# The way /notify is implemented in IRC clients.
sub ison {
  my ($kernel, @nicks) = @_[KERNEL, ARG0 .. $#_];
  my $tmp = "ISON";

  unless (@nicks) {
    warn "No nicknames passed to POE::Component::IRC::ison";
    return;
  }

  # We can pass as many nicks as we want, as long as it's shorter than
  # the maximum command length (510). If the list we get is too long,
  # w'll break it into multiple ISON commands.
  while (@nicks) {
    my $nick = shift @nicks;
    if (length($tmp) + length($nick) >= 509) {
      $kernel->yield( 'sl_high', $tmp );
      $tmp = "ISON";
    }
    $tmp .= " $nick";
  }
  $kernel->yield( 'sl_high', $tmp );
  undef;
}


# Tell the IRC server to forcibly remove a user from a channel.
sub kick {
  my ($kernel, $chan, $nick) = @_[KERNEL, ARG0, ARG1];
  my $message = join '', @_[ARG2 .. $#_];

  unless (defined $chan and defined $nick) {
    warn "The POE::Component::IRC event \"kick\" requires at least two arguments";
    return;
  }

  $nick .= " :$message" if defined $message;
  $kernel->yield( 'sl_high', "KICK $chan $nick" );
  undef;
}

# Tell the IRC server to forcibly remove a user from a channel. Freenode extension
sub remove {
  my ($kernel, $chan, $nick) = @_[KERNEL, ARG0, ARG1];
  my $message = join '', @_[ARG2 .. $#_];

  unless (defined $chan and defined $nick) {
    warn "The POE::Component::IRC event \"remove\" requires at least two arguments";
    return;
  }

  $nick .= " :$message" if defined $message;
  $kernel->yield( 'sl_high', "REMOVE $chan $nick" );
  undef;
}

# Set up a new IRC component. Deprecated.
sub new {
  my ($package, $alias) = splice @_, 0, 2;

  croak "Not enough arguments to POE::Component::IRC::new()" unless $alias;
  warn join ' ', "Use of $package->new() is deprecated, please use spawn(). Called from ", caller(), "\n";
  my $self = $package->spawn ( alias => $alias, options => { @_ } );

  return $self;
}

# Set up a new IRC component. New interface.
sub spawn {
  my $package = shift;
  croak "$package requires an even number of parameters" if @_ & 1;

  my %parms = @_;
  $parms{ lc $_ } = delete $parms{$_} for keys %parms;

  delete $parms{'options'} unless ref ( $parms{'options'} ) eq 'HASH';

  my $self = bless { }, $package;
  $self->_create();

  my $alias = delete $parms{'alias'};

  POE::Session->create(
		object_states => [
		     $self => $self->{OBJECT_STATES_HASHREF},
		     $self => $self->{OBJECT_STATES_ARRAYREF}, ],
		( defined ( $parms{'options'} ) ? ( options => $parms{'options'} ) : () ),
		args => [ $alias ],
		heap => $self, );

  $parms{'CALLED_FROM_SPAWN'} = 1;
  $self->_configure( \%parms );

  return $self;
}


# The handler for all IRC commands that take no arguments.
sub noargs {
  my ($kernel, $state, $arg) = @_[KERNEL, STATE, ARG0];
  my $pri = $_[OBJECT]->{IRC_CMDS}->{$state}->[CMD_PRI];

  if (defined $arg) {
    warn "The POE::Component::IRC event \"$state\" takes no arguments";
    return;
  }
  $kernel->yield( 'sl_prioritized', $pri, $state );
  undef;
}


# The handler for commands that take one required and two optional arguments.
sub oneandtwoopt {
  my ($kernel, $state) = @_[KERNEL, STATE];
  my $arg = join '', @_[ARG0 .. $#_];
  my $pri = $_[OBJECT]->{IRC_CMDS}->{$state}->[CMD_PRI];

  $state = 'connect' if $state eq 'sconnect';
  $state = uc $state;
  if (defined $arg) {
    $arg = ':' . $arg if $arg =~ /\s/;
    $state .= " $arg";
  }
  $kernel->yield( 'sl_prioritized', $pri, $state );
  undef;
}


# The handler for commands that take at least one optional argument.
sub oneoptarg {
  my ($kernel, $state) = @_[KERNEL, STATE];
  my $arg = join '', @_[ARG0 .. $#_] if defined $_[ARG0];
  my $pri = $_[OBJECT]->{IRC_CMDS}->{$state}->[CMD_PRI];

  $state = uc $state;
  if (defined $arg) {
    $arg = ':' . $arg if $arg =~ /\s/;
    $state .= " $arg";
  }
  $kernel->yield( 'sl_prioritized', $pri, $state );
  undef;
}


# The handler for commands which take one required and one optional argument.
sub oneortwo {
  my ($kernel, $state, $one) = @_[KERNEL, STATE, ARG0];
  my $two = join '', @_[ARG1 .. $#_];
  my $pri = $_[OBJECT]->{IRC_CMDS}->{$state}->[CMD_PRI];

  unless (defined $one) {
    warn "The POE::Component::IRC event \"$state\" requires at least one argument";
    return;
  }

  $state = uc( $state ) . " $one";
  $state .= " $two" if defined $two;
  $kernel->yield( 'sl_prioritized', $pri, $state );
  undef;
}


# Handler for commands that take exactly one argument.
sub onlyonearg {
  my ($kernel, $state) = @_[KERNEL, STATE];
  my $arg = join '', @_[ARG0 .. $#_];
  my $pri = $_[OBJECT]->{IRC_CMDS}->{$state}->[CMD_PRI];

  unless (defined $arg) {
    warn "The POE::Component::IRC event \"$state\" requires one argument";
    return;
  }

  $state = uc $state;
  $arg = ':' . $arg if $arg =~ /\s/;
  $state .= " $arg";
  $kernel->yield( 'sl_prioritized', $pri, $state );
  undef;
}


# Handler for commands that take exactly two arguments.
sub onlytwoargs {
  my ($kernel, $state, $one) = @_[KERNEL, STATE, ARG0];
  my ($two) = join '', @_[ARG1 .. $#_];
  my $pri = $_[OBJECT]->{IRC_CMDS}->{$state}->[CMD_PRI];

  unless (defined $one and defined $two) {
    warn "The POE::Component::IRC event \"$state\" requires two arguments";
    return;
  }

  $state = uc $state;
  $two = ':' . $two if $two =~ /\s/;
  $state .= " $one $two";
  $kernel->yield( 'sl_prioritized', $pri, $state );
  undef;
}


# Handler for privmsg or notice events.
sub privandnotice {
  my ($kernel, $state, $to) = @_[KERNEL, STATE, ARG0];
  my $message = join ' ', @_[ARG1 .. $#_];
  my $pri = $_[OBJECT]->{IRC_CMDS}->{$state}->[CMD_PRI];

  $state =~ s/privmsglo/privmsg/;
  $state =~ s/privmsghi/privmsg/;
  $state =~ s/noticelo/notice/;
  $state =~ s/noticehi/notice/;

  unless (defined $to and defined $message) {
    warn "The POE::Component::IRC event \"$state\" requires two arguments";
    return;
  }

  if (ref $to eq 'ARRAY') {
    $to = join ',', @$to;
  }

  $state = uc $state;
  $state .= " $to :$message";
  $kernel->yield( 'sl_prioritized', $pri, $state );
  undef;
}

sub _poco_irc_sig_shutdown {
  my ($kernel,$self,$session,$signal) = @_[KERNEL,OBJECT,SESSION,ARG0];
  $kernel->yield( 'shutdown', @_[ARG1..$#_] );
  return 0;
}

sub _poco_irc_sig_register {
  my ($kernel,$self,$session,$signal,$sender,@events) = @_[KERNEL,OBJECT,SESSION,ARG0..$#_];
  return 0 unless $sender;
  my $session_id = $session->ID();
  my $sender_id;
  if ( my $ref = $kernel->alias_resolve( $sender ) ) {
	$sender_id = $ref->ID();
  } else {
	warn "Can\'t resolve $sender\n";
	return 0;
  }
  unless (@events) {
    warn "Signal POCOIRC: Not enough arguments";
    return 0;
  }

  foreach (@events) {
    $_ = "irc_" . $_ unless /^_/;
    $self->{events}->{$_}->{$sender_id} = $sender_id;
    $self->{sessions}->{$sender_id}->{'ref'} = $sender_id;
    unless ($self->{sessions}->{$sender_id}->{refcnt}++ or $session_id == $sender_id) {
      $kernel->refcount_increment($sender_id, PCI_REFCOUNT_TAG);
    }
  }

  $kernel->post( $sender_id => 'irc_registered' => $self );
  
  return 0;
}

# Ask P::C::IRC to send you certain events, listed in @events.
sub register {
  my ($kernel, $self, $session, $sender, @events) =
    @_[KERNEL, OBJECT, SESSION, SENDER, ARG0 .. $#_];

  unless (@events) {
    warn "register: Not enough arguments";
    return;
  }

  my $sender_id = $sender->ID();
  # FIXME: What "special" event names go here? (ie, "errors")
  # basic, dcc (implies ctcp), ctcp, oper ...what other categories?
  foreach (@events) {
    $_ = "irc_" . $_ unless /^_/;
    $self->{events}->{$_}->{$sender_id} = $sender_id;
    $self->{sessions}->{$sender_id}->{'ref'} = $sender_id;
    unless ($self->{sessions}->{$sender_id}->{refcnt}++ or $session == $sender) {
      $kernel->refcount_increment($sender_id, PCI_REFCOUNT_TAG);
    }
  }
  # BINGOS:
  # Apocalypse is gonna hate me for this as 'irc_registered' events will bypass 
  # the Plugins system, but I can't see how this event will be relevant without 
  # some sort of reference, like what session has registered. I'm not going to
  # start hurling session references around at this point :)

  $kernel->post( $sender => 'irc_registered' => $self );
  undef;
}

# Tell the IRC session to go away.
sub shutdown {
  my ($kernel, $self, $session) = @_[KERNEL, OBJECT, SESSION];
  my $args;
  $args = join '', @_[ARG0..$#_] if scalar @_[ARG0..$#_];
  $args = ':' . $args if $args and $args =~ /\s/;
  my $cmd = join ' ', 'QUIT', $args || '';
  $kernel->sig( 'POCOIRC_REGISTER' );
  $kernel->sig( 'POCOIRC_SHUTDOWN' );
  $self->{_shutdown} = 1;
  $self->_send_event( 'irc_shutdown', $_[SENDER]->ID() );
  $self->_unregister_sessions();
  $kernel->alarm_remove_all();
  $kernel->alias_remove( $_ ) for $kernel->alias_list( $_[SESSION] );
  delete $self->{$_} for qw(sock socketfactory dcc wheelmap);
  # Delete all plugins that are loaded.
  $self->plugin_del( $_ ) for keys %{ $self->plugin_list() };
  $self->{resolver}->shutdown() if $self->{mydns} and $self->{resolver};
  $kernel->call( $session, 'sl_high', $cmd ) if $self->{socket};
  undef;
}


# Send a line of login-priority IRC output.  These are things which
# must go first.
sub sl_login {
  my ($kernel, $self) = @_[KERNEL, OBJECT];
  my $arg = join '', @_[ARG0 .. $#_];
  $kernel->yield( 'sl_prioritized', PRI_LOGIN, $arg );
  undef;
}


# Send a line of high-priority IRC output.  Things like channel/user
# modes, kick messages, and whatever.
sub sl_high {
  my ($kernel, $self) = @_[KERNEL, OBJECT];
  my $arg = join '', @_[ARG0 .. $#_];
  $kernel->yield( 'sl_prioritized', PRI_HIGH, $arg );
  undef;
}


# Send a line of normal-priority IRC output to the server.  PRIVMSG
# and other random chatter.  Uses sl() for compatibility with existing
# code.
sub sl {
  my ($kernel, $self) = @_[KERNEL, OBJECT];
  my $arg = join '', @_[ARG0 .. $#_];

  $kernel->yield( 'sl_prioritized', PRI_NORMAL, $arg );
  undef;
}


# Prioritized sl().  This keeps the queue ordered by priority, low to
# high in the UNIX tradition.  It also throttles transmission
# following the hybrid ircd's algorithm, so you can't accidentally
# flood yourself off.  Thanks to Raistlin for explaining how ircd
# throttles messages.
sub sl_prioritized {
  my ($kernel, $self, $priority, $msg) = @_[KERNEL, OBJECT, ARG0, ARG1];

  # Get the first word for the plugin system
  if ( $msg =~ /^(\w+)\s*/ ) {
  	# Let the plugin system process this
  	if ( $self->_plugin_process( 'USER', $1, \$msg ) == PCI_EAT_ALL ) {
  		return 1;
  	}
  } else {
  	warn "Unable to extract the event name from '$msg'";
  }

  my $now = time();
  $self->{send_time} = $now if $self->{send_time} < $now;

  if (@{$self->{send_queue}}) {
    my $i = @{$self->{send_queue}};
    $i-- while ($i and $priority < $self->{send_queue}->[$i-1]->[MSG_PRI]);
    splice( @{$self->{send_queue}}, $i, 0,
            [ $priority,  # MSG_PRI
              $msg,       # MSG_TEXT
            ]
          );
  } elsif ( $self->{dont_flood} and
            $self->{send_time} - $now >= 10 or not defined $self->{socket}
          ) {
    push( @{$self->{send_queue}},
          [ $priority,  # MSG_PRI
            $msg,       # MSG_TEXT
	   ]
	 );
    $kernel->delay( sl_delayed => $self->{send_time} - $now - 10 );
  } else {
    warn ">>> $msg\n" if $self->{debug};
    $self->{send_time} += 2 + length($msg) / 120;
    $self->{socket}->put($msg);
  }
  undef;
}

# Send delayed lines to the ircd.  We manage a virtual "send time"
# that progresses into the future based on hybrid ircd's rules every
# time a message is sent.  Once we find it ten or more seconds into
# the future, we wait for the realtime clock to catch up.
sub sl_delayed {
  my ($kernel, $self) = @_[KERNEL, OBJECT];

  return unless defined $self->{'socket'};

  my $now = time();
  $self->{send_time} = $now if $self->{send_time} < $now;

  while (@{$self->{send_queue}} and ($self->{send_time} - $now < 10)) {
    my $arg = (shift @{$self->{send_queue}})->[MSG_TEXT];
    warn ">>> $arg\n" if $self->{'debug'};
    $self->{send_time} += 2 + length($arg) / 120;
    $self->{'socket'}->put( "$arg" );
  }

  $kernel->delay( sl_delayed => $self->{send_time} - $now - 10 )
    if @{$self->{send_queue}};
  undef;
}


# The handler for commands which have N arguments, separated by spaces.
sub spacesep {
  my ($kernel, $state) = @_[KERNEL, STATE];
  my $args = join ' ', @_[ARG0 .. $#_];
  my $pri = $_[OBJECT]->{IRC_CMDS}->{$state}->[CMD_PRI];

  $state = uc $state;
  $state .= " $args" if defined $args;
  $kernel->yield( 'sl_prioritized', $pri, $state );
  undef;
}


# Set or query the current topic on a channel.
sub topic {
  my ($kernel,$chan,@args) = @_[KERNEL,ARG0,ARG1..$#_];
  my $topic; 
  $topic = join '', @args if scalar @args;

  if ( defined $topic ) {
     $chan .= " :";
     $chan .= $topic if length $topic;
  }
  $kernel->yield( 'sl_prioritized', PRI_NORMAL, "TOPIC $chan" );
  undef;
}


# Ask P::C::IRC to stop sending you certain events, listed in $evref.
sub unregister {
  my ($kernel, $self, $session, $sender, @events) =
    @_[KERNEL,  OBJECT, SESSION,  SENDER,  ARG0 .. $#_];

  unless (@events) {
    warn "unregister: Not enough arguments";
    return;
  }

  $self->_unregister($session,$sender,@events);
  undef;
}

sub _unregister {
  my ($self,$session,$sender) = splice @_,0,3;
  my $sender_id = $sender->ID();

  foreach (@_) {
    $_ = "irc_" . $_ unless /^_/;
    my $blah = delete $self->{events}->{$_}->{$sender_id};
    unless ( $blah ) {
	warn "$sender_id hasn't registered for '$_' events\n";
	next;
    }
    if (--$self->{sessions}->{$sender_id}->{refcnt} <= 0) {
      delete $self->{sessions}->{$sender_id};
      unless ($session == $sender) {
        $poe_kernel->refcount_decrement($sender_id, PCI_REFCOUNT_TAG);
      }
    }
  }
  undef;
}

sub _unregister_sessions {
  my $self = shift;
  foreach my $session_id ( keys %{ $self->{sessions} } ) {
     my $refcnt = $self->{sessions}->{$session_id}->{refcnt};
     while ( $refcnt --> 0 ) {
	$poe_kernel->refcount_decrement($session_id, PCI_REFCOUNT_TAG) 
     }
     delete $self->{sessions}->{$session_id};
  }
}

# Asks the IRC server for some random information about particular nicks.
sub userhost {
  my ($kernel, @nicks) = @_[KERNEL, ARG0 .. $#_];
  my @five;

  unless (@nicks) {
    warn "No nicknames passed to POE::Component::IRC::userhost";
    return;
  }

  # According to the RFC, you can only send 5 nicks at a time.
  while (@nicks) {
    $kernel->yield( 'sl_prioritized', PRI_HIGH,
		    "USERHOST " . join(' ', splice(@nicks, 0, 5)) );
  }
  undef;
}

# Non-event methods

sub version {
  return $VERSION;
}

sub server_name {
  my $self = shift;
  return $self->{INFO}->{ServerName};
}

sub nick_name {
  my $self = shift;
  return $self->{RealNick};
}

sub send_queue {
  my $self = shift;
  if ( defined ( $self->{send_queue} ) and ref ( $self->{send_queue} ) eq 'ARRAY' ) {
	return scalar @{ $self->{send_queue} };
  }
  return 0;
}

sub raw_events {
  my $self = shift;
  my $value = shift;
  return $self->{raw_events} unless defined $value;
  $self->{raw_events} = $value;
}

sub session_id {
  my $self = shift;
  return $self->{SESSION_ID};
}

sub session_alias {
  my $self = shift;
  return $self->{alias};
}

sub yield {
  my $self = shift;
  $poe_kernel->post( $self->session_id() => @_ );
}

sub call {
  my $self = shift;
  $poe_kernel->call( $self->session_id() => @_ );
}

sub delay {
  my $self = shift;
  my $arrayref = shift || return;
  unless ( ref $arrayref eq 'ARRAY' ) {
	warn "First argument to delay() must be an ARRAYREF\n";
	return;
  }
  $poe_kernel->call( $self->session_id() => '_delayed_cmd' => $arrayref => @_ );
}

sub delay_remove {
  my $self = shift;
  $poe_kernel->call( $self->session_id(), '_delay_remove', @_ );
}

sub _delayed_cmd {
  my ($kernel,$self,$arrayref,$time) = @_[KERNEL,OBJECT,ARG0,ARG1];
  return unless scalar @{ $arrayref };
  return unless $time;
  my $event = shift @{ $arrayref };
  my $alarm_id = $kernel->delay_set( $event => $time => @{ $arrayref } );
  $self->send_event( 'irc_delay_set', $alarm_id, $event, @{ $arrayref } ) if $alarm_id;
  return $alarm_id;
}

sub _delay_remove {
  my ($kernel,$self,$alarm_id) = @_[KERNEL,OBJECT,ARG0];
  return unless $alarm_id;
  my @old_alarm_list = $kernel->alarm_remove( $alarm_id );
  if ( @old_alarm_list ) {
    splice @old_alarm_list, 1, 1;
    $self->send_event( 'irc_delay_removed', $alarm_id, @old_alarm_list );
    return \@old_alarm_list;
  }
  return;
}

sub _validate_command {
  my $self = shift;
  my $cmd = lc ( $_[0] ) || return 0;

  foreach my $command ( keys %{ $self->{IRC_CMDS} } ) {
	if ( $cmd eq $command ) {
		return 1;
	}
  }
  return 0;
}

sub connected {
  my $self = shift;
  return $self->{connected};
}

sub _compress_uplink {
  my ($self,$value) = splice @_, 0, 2;
  return unless $self->{can_do_zlib};
  return $self->{uplink} unless defined $value;
  if ( $value ) {
	$self->{out_filter}->unshift( POE::Filter::Zlib::Stream->new() ) unless $self->{uplink};
	$self->{uplink} = 1;
  } else {
	$self->{out_filter}->shift() if $self->{uplink};
	$self->{uplink} = 0;
  }
  return $self->{uplink};
}

sub _compress_downlink {
  my ($self,$value) = splice @_, 0, 2;
  return unless $self->{can_do_zlib};
  return $self->{downlink} unless defined $value;
  if ( $value ) {
	$self->{srv_filter}->unshift( POE::Filter::Zlib::Stream->new() ) unless $self->{downlink};
	$self->{downlink} = 1;
  } else {
	$self->{srv_filter}->shift() if $self->{uplink};
	$self->{downlink} = 0;
  }
  return $self->{downlink};
}

# Automatically replies to a PING from the server. Do not confuse this
# with CTCP PINGs, which are a wholly different animal that evolved
# much later on the technological timeline.
sub S_ping {
  my ($self, $irc) = splice @_, 0, 2;
  my $arg = ${ $_[0] };
  $irc->yield( 'sl_login', "PONG :$arg" );
  undef;
}

# NICK messages for the purposes of determining our current nickname
sub S_nick {
  my ($self, $irc) = splice @_, 0, 2;
  my $nick = ( split /!/, ${ $_[0] } )[0];
  my $new = ${ $_[1] };
  $self->{RealNick} = $new if ( $nick eq $self->{RealNick} );
  undef;
}

# accesses the ISupport plugin
sub isupport {
  my ($self) = shift;
  return $self->{isupport}->isupport(@_);
}

sub isupport_dump_keys {
  return $_[0]->{isupport}->isupport_dump_keys();
}

sub resolver {
  return $_[0]->{resolver};
}

# accesses the plugin pipeline
sub pipeline {
  my ($self) = @_;
  $self->{PLUGINS} = POE::Component::IRC::Pipeline->new($self)
    unless UNIVERSAL::isa($self->{PLUGINS}, 'POE::Component::IRC::Pipeline');
  return $self->{PLUGINS};
}

# Adds a new plugin object
sub plugin_add {
  my ($self, $name, $plugin) = @_;
  my $pipeline = $self->pipeline;

  unless (defined $name and defined $plugin) {
    warn 'Please supply a name and the plugin object to be added!';
    return;
  }

  return $pipeline->push($name => $plugin);
}

# Removes a plugin object
sub plugin_del {
  my ($self, $name) = @_;

  unless (defined $name) {
    warn 'Please supply a name/object for the plugin to be removed!';
    return;
  }

  my $return = scalar $self->pipeline->remove($name);
  warn "$@\n" if $@;
  return $return;
}

# Gets the plugin object
sub plugin_get {
  my ($self, $name) = @_;  

  unless (defined $name) {
    warn 'Please supply a name/object for the plugin to be removed!';
    return;
  }

  return scalar $self->pipeline->get($name);
}

# Lists loaded plugins
sub plugin_list {
  my ($self) = @_;
  my $pipeline = $self->pipeline;
  my %return;

  for (@{ $pipeline->{PIPELINE} }) {
    $return{ $pipeline->{PLUGS}{$_} } = $_;
  }

  return \%return;
}

# Lists loaded plugins in order!
sub plugin_order {
  my ($self) = @_;
  return $self->pipeline->{PIPELINE};
}

# Lets a plugin register for certain events
sub plugin_register {
  my ($self, $plugin, $type, @events) = @_;
  my $pipeline = $self->pipeline;

  unless (defined $type and ($type eq 'SERVER' or $type eq 'USER')) {
    warn 'Type should be SERVER or USER!';
    return;
  }

  unless (defined $plugin) {
    warn 'Please supply the plugin object to register!';
    return;
  }

  unless (@events) {
    warn 'Please supply at least one event to register!';
    return;
  }

  for my $ev (@events) {
    if (ref($ev) and ref($ev) eq "ARRAY") {
      @{ $pipeline->{HANDLES}{$plugin}{$type} }{ map lc, @$ev } = (1) x @$ev;
    }
    else {
      $pipeline->{HANDLES}{$plugin}{$type}{lc $ev} = 1;
    }
  }

  return 1;
}

# Lets a plugin unregister events
sub plugin_unregister {
  my ($self, $plugin, $type, @events) = @_;
  my $pipeline = $self->pipeline;

  unless (defined $type and ($type eq 'SERVER' or $type eq 'USER')) {
    warn 'Type should be SERVER or USER!';
    return;
  }

  unless (defined $plugin) {
    warn 'Please supply the plugin object to register!';
    return;
  }

  unless (@events) {
    warn 'Please supply at least one event to unregister!';
    return;
  }

  for my $ev (@events) {
    if (ref($ev) and ref($ev) eq "ARRAY") {
      for my $e (map lc, @$ev) {
        unless (delete $pipeline->{HANDLES}{$plugin}{$type}{$e}) {
          warn "The event '$e' does not exist!";
          next;
        }
      }
    }
    else {
      $ev = lc $ev;
      unless (delete $pipeline->{HANDLES}{$plugin}{$type}{$ev}) {
        warn "The event '$ev' does not exist!";
        next;
      }
    }
  }

  return 1;
}

# Process an input event for plugins
sub _plugin_process {
  my ($self, $type, $event, @args) = @_;
  my $pipeline = $self->pipeline;

  $event = lc $event;
  $event =~ s/^irc_//;

  my $sub = ($type eq 'SERVER' ? "S" : "U") . "_$event";
  my $return = PCI_EAT_NONE;

  eval { $self->$sub( $self, @args ) } if $self->can($sub);
  warn "$@" if $@;

  for my $plugin (@{ $pipeline->{PIPELINE} }) {
    next if $self eq $plugin;
    next
      unless $pipeline->{HANDLES}{$plugin}{$type}{$event}
      or $pipeline->{HANDLES}{$plugin}{$type}{all};

    my $ret = PCI_EAT_NONE;

    if ( $plugin->can($sub) ) {
      eval { $ret = $plugin->$sub($self,@args) };
      warn "$sub call failed with '$@'\n" if $@ and $self->{plugin_debug};
    } elsif ( $plugin->can('_default') ) {
      eval { $ret = $plugin->_default($self,$sub,@args) };
      warn "_default call failed with '$@'\n" if $@ and $self->{plugin_debug};
    }

    return $return if $ret == PCI_EAT_PLUGIN;
    $return = PCI_EAT_ALL if $ret == PCI_EAT_CLIENT;
    return PCI_EAT_ALL if $ret == PCI_EAT_ALL;
  }

  return $return;
}  

1;
__END__

=head1 NAME

POE::Component::IRC - a fully event-driven IRC client module.

=head1 SYNOPSIS

  # A simple Rot13 'encryption' bot

  use strict;
  use warnings;
  use POE qw(Component::IRC);

  my $nickname = 'Flibble' . $$;
  my $ircname = 'Flibble the Sailor Bot';
  my $ircserver = 'irc.blahblahblah.irc';
  my $port = 6667;

  my @channels = ( '#Blah', '#Foo', '#Bar' );

  # We create a new PoCo-IRC object and component.
  my $irc = POE::Component::IRC->spawn( 
	nick => $nickname,
	server => $ircserver,
	port => $port,
	ircname => $ircname,
  ) or die "Oh noooo! $!";

  POE::Session->create(
	package_states => [
		'main' => [ qw(_default _start irc_001 irc_public) ],
	],
	heap => { irc => $irc },
  );

  $poe_kernel->run();
  exit 0;

  sub _start {
    my ($kernel,$heap) = @_[KERNEL,HEAP];

    # We get the session ID of the component from the object
    # and register and connect to the specified server.
    my $irc_session = $heap->{irc}->session_id();
    $kernel->post( $irc_session => register => 'all' );
    $kernel->post( $irc_session => connect => { } );
    undef;
  }

  sub irc_001 {
    my ($kernel,$sender) = @_[KERNEL,SENDER];

    # Get the component's object at any time by accessing the heap of
    # the SENDER
    my $poco_object = $sender->get_heap();
    print "Connected to ", $poco_object->server_name(), "\n";

    # In any irc_* events SENDER will be the PoCo-IRC session
    $kernel->post( $sender => join => $_ ) for @channels;
    undef;
  }

  sub irc_public {
    my ($kernel,$sender,$who,$where,$what) = @_[KERNEL,SENDER,ARG0,ARG1,ARG2];
    my $nick = ( split /!/, $who )[0];
    my $channel = $where->[0];

    if ( my ($rot13) = $what =~ /^rot13 (.+)/ ) {
	$rot13 =~ tr[a-zA-Z][n-za-mN-ZA-M];
	$kernel->post( $sender => privmsg => $channel => "$nick: $rot13" );
    }
    undef;
  }

  # We registered for all events, this will produce some debug info.
  sub _default {
    my ($event, $args) = @_[ARG0 .. $#_];
    my @output = ( "$event: " );

    foreach my $arg ( @$args ) {
        if ( ref($arg) eq 'ARRAY' ) {
                push( @output, "[" . join(" ,", @$arg ) . "]" );
        } else {
                push ( @output, "'$arg'" );
        }
    }
    print STDOUT join ' ', @output, "\n";
    return 0;
  }

  # A Multiple Network Rot13 'encryption' bot

  use strict;
  use warnings;
  use POE qw(Component::IRC);

  my $nickname = 'Flibble' . $$;
  my $ircname = 'Flibble the Sailor Bot';
  my $port = 6667;

  my $settings = { 
	'server1.irc' => { port => 6667, channels => [ '#Foo' ], },
	'server2.irc' => { port => 6668, channels => [ '#Bar' ], },
	'server3.irc' => { port => 7001, channels => [ '#Baa' ], },
  };

  # We create a new PoCo-IRC objects and components.
  foreach my $server ( keys %{ $settings } ) {
	POE::Component::IRC->spawn( 
		alias   => $server, 
		nick    => $nickname,
		ircname => $ircname,  
	);
  }

  POE::Session->create(
	package_states => [
		'main' => [ qw(_default _start irc_registered irc_001 irc_public) ],
	],
	heap => { config => $settings },
  );

  $poe_kernel->run();
  exit 0;

  sub _start {
    my ($kernel,$session) = @_[KERNEL,SESSION];

    # Send a POCOIRC_REGISTER signal to all poco-ircs
    $kernel->signal( $kernel, 'POCOIRC_REGISTER', $session->ID(), 'all' );

    undef;
  }

  # We'll get one of these from each PoCo-IRC that we spawned above.
  sub irc_registered {
    my ($kernel,$heap,$sender,$irc_object) = @_[KERNEL,HEAP,SENDER,ARG0];

    my $alias = $irc_object->session_alias();

    my %conn_hash = (
	server => $alias,
	port   => $heap->{config}->{ $alias }->{port},
    );

    # In any irc_* events SENDER will be the PoCo-IRC session
    $kernel->post( $sender, 'connect', \%conn_hash ); 

    undef;
  }

  sub irc_001 {
    my ($kernel,$heap,$sender) = @_[KERNEL,HEAP,SENDER];

    # Get the component's object at any time by accessing the heap of
    # the SENDER
    my $poco_object = $sender->get_heap();
    print "Connected to ", $poco_object->server_name(), "\n";

    my $alias = $poco_object->session_alias();
    my @channels = @{ $heap->{config}->{ $alias }->{channels} };

    $kernel->post( $sender => join => $_ ) for @channels;

    undef;
  }

  sub irc_public {
    my ($kernel,$sender,$who,$where,$what) = @_[KERNEL,SENDER,ARG0,ARG1,ARG2];
    my $nick = ( split /!/, $who )[0];
    my $channel = $where->[0];

    if ( my ($rot13) = $what =~ /^rot13 (.+)/ ) {
	$rot13 =~ tr[a-zA-Z][n-za-mN-ZA-M];
	$kernel->post( $sender => privmsg => $channel => "$nick: $rot13" );
    }

    if ( $what =~ /^!bot_quit$/ ) {
	# Someone has told us to die =[
	$kernel->signal( $kernel, 'POCOIRC_SHUTDOWN', "See you loosers" );
    }
    undef;
  }

  # We registered for all events, this will produce some debug info.
  sub _default {
    my ($event, $args) = @_[ARG0 .. $#_];
    my @output = ( "$event: " );

    foreach my $arg ( @$args ) {
        if ( ref($arg) eq 'ARRAY' ) {
                push( @output, "[" . join(" ,", @$arg ) . "]" );
        } else {
                push ( @output, "'$arg'" );
        }
    }
    print STDOUT join ' ', @output, "\n";
    return 0;
  }

=head1 DESCRIPTION

POE::Component::IRC is a POE component (who'd have guessed?) which
acts as an easily controllable IRC client for your other POE
components and sessions. You create an IRC component and tell it what
events your session cares about and where to connect to, and it sends
back interesting IRC events when they happen. You make the client do
things by sending it events. That's all there is to it. Cool, no?

[Note that using this module requires some familiarity with the
details of the IRC protocol. I'd advise you to read up on the gory
details of RFC 1459
E<lt>http://www.faqs.org/rfcs/rfc1459.htmlE<gt> before you
get started. Keep the list of server numeric codes handy while you
program. Needless to say, you'll also need a good working knowledge of
POE, or this document will be of very little use to you.]

The POE::Component::IRC distribution has a docs/ folder with a collection of
salient documentation including the pertinent RFCs.

POE::Component::IRC consists of a POE::Session that manages the IRC connection and 
dispatches 'irc_' prefixed events to interested sessions and 
an object that can be used to access additional information using methods.

Sessions register their interest in receiving 'irc_' events by sending 'register' to the component. One would usually do this in your _start handler. Your session will continue to receive events until you 'unregister'. The component will continue to stay around until you tell it not to with 'shutdown'.

The SYNOPSIS demonstrates a fairly basic bot.

=head1 Useful subclasses

Included with POE::Component::IRC are a number of useful subclasses. As they are subclasses they support all the methods, etc. documented here and have additional methods and quirks which are documented separately:

=over

=item L<POE::Component::IRC::State>

POE::Component::IRC::State provides all the functionality of POE::Component::IRC but also tracks IRC state entities such as nicks and channels.

=item L<POE::Component::IRC::Qnet>

POE::Component::IRC::Qnet is POE::Component::IRC tweaked for use on Quakenet IRC network.

=item L<POE::Component::IRC::Qnet::State>

POE::Component::IRC::Qnet::State is a tweaked version of POE::Component::IRC::State for use on Quakenet IRC network. 

=back

=head1 The Plugin system

As of 3.7, PoCo-IRC sports a plugin system. The documentation for it can be read by looking
at L<POE::Component::IRC::Plugin>. That is not a subclass, just a placeholder for documentation!

A number of useful plugins have made their way into the core distribution:

=over 

=item L<POE::Component::IRC::Plugin::Connector>

Glues an irc bot to an IRC network, ie. deals with maintaining ircd connections.

=item L<POE::Component::IRC::Plugin::BotTraffic>

Under normal circumstances irc bots do not normal the msgs and public msgs that they generate themselves. This plugin enables you to handle those events.

=item L<POE::Component::IRC::Plugin::BotAddressed>

Generates 'irc_bot_addressed' events whenever someone addresses your bot by name in a channel.

=item L<POE::Component::IRC::Plugin::Console>

See inside the component. See what events are being sent. Generate irc commands manually. A TCP based console.

=item L<POE::Component::IRC::Plugin::Proxy>

A lightweight IRC proxy/bouncer.

=item L<POE::Component::IRC::Plugin::CTCP>

Automagically generates replies to ctcp version, time and userinfo queries.

=item L<POE::Component::IRC::Plugin::PlugMan>

An experimental Plugin Manager plugin.

=item L<POE::Component::IRC::Plugin::NickReclaim>

Automagically deals with your nickname being in use and reclaiming it.

=back

=head1 CONSTRUCTORS

Both CONSTRUCTORS return an object. The object is also available within 'irc_' event handlers by using 
$_[SENDER]->get_heap(). See also 'register' and 'irc_registered'.

=over

=item spawn

Takes a number of arguments, all of which are optional: 

  "alias", a name (kernel alias) that this instance will be known by;
  "options", a hashref containing POE::Session options;

  "Server", the server name;
  "Port", the remote port number;
  "Password", an optional password for restricted servers;
  "Nick", your client's IRC nickname;
  "Username", your client's username;
  "Ircname", some cute comment or something.

  "UseSSL", set to some true value if you want to connect using SSL.
  "Raw", set to some true value to enable the component to send 'irc_raw' events.
  "LocalAddr", which local IP address on a multihomed box to connect as;
  "LocalPort", the local TCP port to open your socket on;
  "NoDNS", set this to 1 to disable DNS lookups using PoCo-Client-DNS. ( See note below ).
  "Flood", set this to 1 to get quickly disconnected and klined from an ircd >;]
  "Proxy", IP address or server name of a proxy server to use.
  "ProxyPort", which tcp port on the proxy to connect to.
  "NATAddr", what other clients see as your IP address.
  "DCCPorts", an arrayref containing tcp ports that can be used for DCC sends.
  "Resolver", provide a POE::Component::Client::DNS object for the component to use.
  "plugin_debug", set to some true value to print plugin debug info, default 0.
  "socks_proxy", specify a SOCKS4/SOCKS4a proxy to use.
  "socks_port", the SOCKS port to use, defaults to 1080 if not specified.
  "socks_id", specify a SOCKS user_id. Default is none.
  "useipv6", enable the use of IPv6 for connections.

C<spawn> will supply
reasonable defaults for any of these attributes which are missing, so
don't feel obliged to write them all out.

All the above options may be supplied to C<connect()> input event as well.

If the component finds that L<POE::Component::Client::DNS|POE::Component::Client::DNS>
is installed it will use that to resolve the server name passed. Disable this
behaviour if you like, by passing: NoDNS => 1.

Additionally there is a "Flood" parameter.  When true, it disables the
component's flood protection algorithms, allowing it to send messages
to an IRC server at full speed.  Disconnects and k-lines are some
common side effects of flooding IRC servers, so care should be used
when enabling this option.

Two new attributes are "Proxy" and "ProxyPort" for sending your
IRC traffic through a proxy server.  "Proxy"'s value should be the IP
address or server name of the proxy.  "ProxyPort"'s value should be the
port on the proxy to connect to.  C<connect()> will default to using the
I<actual> IRC server's port if you provide a proxy but omit the proxy's
port. These are for HTTP Proxies. See 'socks_proxy' for SOCKS4 and SOCKS4a support.

For those people who run bots behind firewalls and/or Network Address Translation
there are two additional attributes for DCC. "DCCPorts", is an arrayref of ports
to use when initiating DCC, using dcc(). "NATAddr", is the NAT'ed IP address that your bot is
hidden behind, this is sent whenever you do DCC.

SSL support requires POE::Component::SSLify, as well as an IRC server that supports
SSL connections. If you're missing POE::Component::SSLify, specifing 'UseSSL' will do
nothing. The default is to not try to use SSL.

Setting 'Raw' to true, will enable the component to send 'irc_raw' events to interested plugins
and sessions. See below for more details on what a 'irc_raw' events is :)

'NoDNS' has different results depending on whether it is set with spawn() or connect(). Setting it
with spawn(), disables the creation of the POE::Component::Client::DNS completely. Setting it with
connect() on the other hand allows the PoCo-Client-DNS session to be spawned, but will disable any 
dns lookups using it.

'Resolver', requires a POE::Component::Client::DNS object. Useful when spawning multiple poco-irc sessions
, saves the overhead of multiple dns sessions.

'plugin_debug', setting to true enables plugin debug info. Plugins are processed inside an eval, so debugging them can be hard. This should help with that.

SOCKS4 proxy support is provided by 'socks_proxy', 'socks_port' and 'socks_id' parameters. If something goes wrong
with the SOCKS connection you should get a warning on STDERR. This is fairly experimental currently.

IPv6 support is available for connecting to IPv6 enabled ircds ( it won't work for DCC though ). To enable it, specify 'useipv6'. L<Socket6> is required to be installed.
If you have L<Socket6> and L<POE::Component::Client::DNS> installed and specify a hostname that resolves to an IPv6 address then IPv6 will be used. If you specify an ipv6 'localaddr' then IPv6 will be used.

=item new

This method is deprecated. See 'spawn' method instead.
Takes one argument: a name (kernel alias) which this new connection
will be known by. Returns a POE::Component::IRC object :)
Use of this method will generate a warning. There are currently no plans to make it die() >;]

=back

=head1 METHODS

These are methods supported by the POE::Component::IRC object. 

=over

=item server_name

Takes no arguments. Returns the name of the IRC server that the component
is currently connected to.

=item nick_name

Takes no arguments. Returns a scalar containing the current nickname that the
bot is using.

=item session_id

Takes no arguments. Returns the ID of the component's session. Ideal for posting
events to the component.

$kernel->post( $irc->session_id() => 'mode' => $channel => '+o' => $dude );

=item session_alias

Takes no arguments. Returns the session alias that has been set through spawn()'s alias argument. 

=item version

Takes no arguments. Returns the version number of the module.

=item send_queue

The component provides anti-flood throttling. This method takes no arguments and returns a scalar
representing the number of messages that are queued up waiting for dispatch to the irc server.

=item connected 

Takes no arguments. Returns true or false depending on whether the component is currently
connected to an IRC network or not.

=item disconnect

Takes no arguments. Terminates the socket connection disgracefully >;o]

=item raw_events

With no arguments, returns true or false depending on whether 'irc_raw' events are being 
generated or not. Provide a true or false argument to enable or disable this feature accordingly.

=item isupport

Takes one argument, a server capability to query. Returns undef on failure or a value representing the applicable capability. A full list of capabilities is available at L<http://www.irc.org/tech_docs/005.html>.

=item isupport_dump_keys

Takes no arguments, returns a list of the available server capabilities keys, which can be used with isupport().

=item yield

This method provides an alternative object based means of posting events to the component.
First argument is the event to post, following arguments are sent as arguments to the resultant
post.

  $irc->yield( 'mode' => $channel => '+o' => $dude );

=item call

This method provides an alternative object based means of calling events to the component.
First argument is the event to call, following arguments are sent as arguments to the resultant
call.

  $irc->call( 'mode' => $channel => '+o' => $dude );

=item delay

This method provides a way of posting delayed events to the component. The first argument
is an arrayref consisting of the delayed command to post and any command arguments. The 
second argument is the time in seconds that one wishes to delay the command being posted.

  my $alarm_id = $irc->delay( [ 'mode' => $channel => '+o' => $dude ], 60 );

Returns an alarm ID that can be used with delay_remove() to cancel the delayed event. This
will be undefined if something went wrong.

=item delay_remove

This method removes a previously scheduled delayed event from the component. Takes one
argument, the alarm_id that was returned by a delay() method call.

  my $arrayref = $irc->delay_remove( $alarm_id );

Returns an arrayref that was originally requested to be delayed.

=item resolver

Returns a reference to the L<POE::Component::Client::DNS> object that is internally 
created by the component.

=item pipeline

Returns a reference to the L<POE::Component::IRC::Pipeline> object used by the plugin system.

=item send_event

Sends an event through the components event handling system. These will get processed by 
plugins then by registered sessions. First argument is the event name, followed by any parameters for that event.

=back

=head1 INPUT

How to talk to your new IRC component... here's the events we'll accept.
These are events that are posted to the component, either via $poe_kernel->post() or via 
the object method yield().

So the following would be functionally equivalent:

  sub irc_001 {
    my ($kernel,$sender) = @_[KERNEL,SENDER];
    my $irc = $sender->get_heap(); # obtain the poco's object

    $irc->yield( privmsg => 'foo' => 'Howdy!' );
    $kernel->post( $sender => privmsg => 'foo' => 'Howdy!' );
    $kernel->post( $irc->session_id() => privmsg => 'foo' => 'Howdy!' );
    $kernel->post( $irc->session_alias() => privmsg => 'foo' => 'Howdy!' );

    undef;
  }

=head2 Important Commands

=over

=item register

Takes N arguments: a list of event names that your session wants to
listen for, minus the "irc_" prefix. So, for instance, if you just
want a bot that keeps track of which people are on a channel, you'll
need to listen for JOINs, PARTs, QUITs, and KICKs to people on the
channel you're in. You'd tell POE::Component::IRC that you want those
events by saying this:

  $kernel->post( 'my client', 'register', qw(join part quit kick) );

Then, whenever people enter or leave a channel your bot is on (forcibly
or not), your session will receive events with names like "irc_join",
"irc_kick", etc., which you can use to update a list of people on the
channel.

Registering for C<'all'> will cause it to send all IRC-related events to
you; this is the easiest way to handle it. See the test script for an
example.

Registering will generate an 'irc_registered' event that your session can
trap. ARG0 is the components object. Useful if you want to bolt PoCo-IRC's
new features such as Plugins into a bot coded to the older deprecated API.
If you are using the new API, ignore this :)

Registering with multiple component sessions can be tricky, especially if
one wants to marry up sessions/objects, etc. Check 'SIGNALS' section of this
documentation for an alternative method of registering with multiple poco-ircs.

Starting with version 4.96, if you spawn the component from inside another POE
session, the component will automatically register that session as wanting 'all'
irc events. That session will receive an 'irc_registered' event indicating that
the component is up and ready to go.

=item connect

Takes one argument: a hash reference of attributes for the new
connection, see C<spawn()> for details. This event tells the IRC client to connect to a
new/different server. If it has a connection already open, it'll close
it gracefully before reconnecting.

=item ctcp and ctcpreply

Sends a CTCP query or response to the nick(s) or channel(s) which you
specify. Takes 2 arguments: the nick or channel to send a message to
(use an array reference here to specify multiple recipients), and the
plain text of the message to send (the CTCP quoting will be handled
for you). The "/me" command in popular IRC clients is actually a CTCP action.

   # Doing a /me 
   $poe_kernel->post( $irc_session => ctcp => $channel => "ACTION dances." );

=item dcc

Send a DCC SEND or CHAT request to another person. Takes at least two
arguments: the nickname of the person to send the request to and the
type of DCC request (SEND or CHAT). For SEND requests, be sure to add
a third argument for the filename you want to send. Optionally, you
can add a fourth argument for the DCC transfer blocksize, but the
default of 1024 should usually be fine.

Incidentally, you can send other weird nonstandard kinds of DCCs too;
just put something besides 'SEND' or 'CHAT' (say, "FOO") in the type
field, and you'll get back "irc_dcc_foo" events when activity happens
on its DCC connection.

If you are behind a firewall or Network Address Translation, you may want to
consult 'connect()' for some parameters that are useful with this command.

=item dcc_accept

Accepts an incoming DCC connection from another host. First argument:
the magic cookie from an 'irc_dcc_request' event. In the case of a DCC
GET, the second argument can optionally specify a new name for the
destination file of the DCC transfer, instead of using the sender's name
for it. (See the 'irc_dcc_request' section below for more details.)

=item dcc_chat

Sends lines of data to the person on the other side of a DCC CHAT
connection. Takes any number of arguments: the magic cookie from an
'irc_dcc_start' event, followed by the data you wish to send. (It'll be
chunked into lines by a POE::Filter::Line for you, don't worry.)

=item dcc_close

Terminates a DCC SEND or GET connection prematurely, and causes DCC CHAT
connections to close gracefully. Takes one argument: the magic cookie
from an 'irc_dcc_start' or 'irc_dcc_request' event.

=item join

Tells your IRC client to join a single channel of your choice. Takes
at least one arg: the channel name (required) and the channel key
(optional, for password-protected channels).

=item kick

Tell the IRC server to forcibly evict a user from a particular
channel. Takes at least 2 arguments: a channel name, the nick of the
user to boot, and an optional witty message to show them as they sail
out the door.

=item remove ( Freenode only )

Tell the IRC server to forcibly evict a user from a particular
channel. Takes at least 2 arguments: a channel name, the nick of the
user to boot, and an optional witty message to show them as they sail
out the door. Similar to KICK but does an enforced PART instead.

=item mode

Request a mode change on a particular channel or user. Takes at least
one argument: the mode changes to effect, as a single string (e.g.,
"+sm-p+o"), and any number of optional operands to the mode changes
(nicks, hostmasks, channel keys, whatever.) Or just pass them all as one
big string and it'll still work, whatever. I regret that I haven't the
patience now to write a detailed explanation, but serious IRC users know
the details anyhow.

=item nick

Allows you to change your nickname. Takes exactly one argument: the
new username that you'd like to be known as.

=item notice

Sends a NOTICE message to the nick(s) or channel(s) which you
specify. Takes 2 arguments: the nick or channel to send a notice to
(use an array reference here to specify multiple recipients), and the
text of the notice to send.

=item part

Tell your IRC client to leave the channels which you pass to it. Takes
any number of arguments: channel names to depart from.

=item privmsg

Sends a public or private message to the nick(s) or channel(s) which
you specify. Takes 2 arguments: the nick or channel to send a message
to (use an array reference here to specify multiple recipients), and
the text of the message to send.

To send IRC colours wrap the text you want coloured with \x03 followed
by the colour code, your text and a \x03 to switch back.

  $kernel->post( $sender => privmsg => $channel => "Foo \x034bar\x03" );

The colour codes are:

    1 - Black
    2 - Navy Blue
    3 - Green
    4 - Red
    5 - Brown
    6 - Purple
    7 - Olive
    8 - Yellow
    9 - Lime Green
    10 - Teal
    11 - Aqua Light
    12 - Royal Blue
    13 - Hot Pink
    14 - Dark Gray
    15 - Light Gray
    16 - White 

=item quit

Tells the IRC server to disconnect you. Takes one optional argument:
some clever, witty string that other users in your channels will see
as you leave. You can expect to get an C<irc_disconnect> event shortly
after sending this.

=item shutdown

By default, POE::Component::IRC sessions never go away. Even after
they're disconnected, they're still sitting around in the background,
waiting for you to call C<connect()> on them again to reconnect.
(Whether this behavior is the Right Thing is doubtful, but I don't want
to break backwards compatibility at this point.) You can send the IRC
session a C<shutdown> event manually to make it delete itself.

If you are connected, 'shutdown' will send a quit message to ircd and
disconnect. If you provide an argument that will be used as the QUIT
message.

Terminating multiple components can be tricky. Check the 'SIGNALS' section of
this documentation for an alternative method of shutting down multiple poco-ircs.

=item unregister

Takes N arguments: a list of event names which you I<don't> want to
receive. If you've previously done a 'register' for a particular event
which you no longer care about, this event will tell the IRC
connection to stop sending them to you. (If you haven't, it just
ignores you. No big deal.)

If you have registered with 'all', attempting to unregister individual 
events such as 'mode', etc. will not work. This is a 'feature'.

=item debug

Takes 1 argument: 0 to turn debugging off or 1 to turn debugging on.
This turns debugging on in POE::Filter::IRC, POE::Filter::CTCP, and
POE::Component::IRC. This has the same effect as setting Debug to true
in 'connect'.

=back

=head2 Not-So-Important Commands

=over

=item admin

Asks your server who your friendly neighborhood server administrators
are. If you prefer, you can pass it a server name to query, instead of
asking the server you're currently on.

=item away

When sent with an argument (a message describig where you went), the
server will note that you're now away from your machine or otherwise
preoccupied, and pass your message along to anyone who tries to
communicate with you. When sent without arguments, it tells the server
that you're back and paying attention.

=item info

Basically the same as the "version" command, except that the server is
permitted to return any information about itself that it thinks is
relevant. There's some nice, specific standards-writing for ya, eh?

=item invite

Invites another user onto an invite-only channel. Takes 2 arguments:
the nick of the user you wish to admit, and the name of the channel to
invite them to.

=item ison

Asks the IRC server which users out of a list of nicknames are
currently online. Takes any number of arguments: a list of nicknames
to query the IRC server about.

=item links

Asks the server for a list of servers connected to the IRC
network. Takes two optional arguments, which I'm too lazy to document
here, so all you would-be linklooker writers should probably go dig up
the RFC.

=item list

Asks the server for a list of visible channels and their topics. Takes
any number of optional arguments: names of channels to get topic
information for. If called without any channel names, it'll list every
visible channel on the IRC network. This is usually a really big list,
so don't do this often.

=item motd

Request the server's "Message of the Day", a document which typically
contains stuff like the server's acceptable use policy and admin
contact email addresses, et cetera. Normally you'll automatically
receive this when you log into a server, but if you want it again,
here's how to do it. If you'd like to get the MOTD for a server other
than the one you're logged into, pass it the server's hostname as an
argument; otherwise, no arguments.

=item names

Asks the server for a list of nicknames on particular channels. Takes
any number of arguments: names of channels to get lists of users
for. If called without any channel names, it'll tell you the nicks of
everyone on the IRC network. This is a really big list, so don't do
this much.

=item quote

Sends a raw line of text to the server. Takes one argument: a string
of a raw IRC command to send to the server. It is more optimal to use
the events this module supplies instead of writing raw IRC commands
yourself.

=item stats

Returns some information about a server. Kinda complicated and not
terribly commonly used, so look it up in the RFC if you're
curious. Takes as many arguments as you please.

=item time

Asks the server what time it thinks it is, which it will return in a
human-readable form. Takes one optional argument: a server name to
query. If not supplied, defaults to current server.

=item topic

Retrieves or sets the topic for particular channel. If called with just
the channel name as an argument, it will ask the server to return the
current topic. If called with the channel name and a string, it will
set the channel topic to that string. Supply an empty string to unset a
channel topic.

=item trace

If you pass a server name or nick along with this request, it asks the
server for the list of servers in between you and the thing you
mentioned. If sent with no arguments, it will show you all the servers
which are connected to your current server.

=item userhost

Asks the IRC server for information about particular nicknames. (The
RFC doesn't define exactly what this is supposed to return.) Takes any
number of arguments: the nicknames to look up.

=item users

Asks the server how many users are logged into it. Defaults to the
server you're currently logged into; however, you can pass a server
name as the first argument to query some other machine instead.

=item version

Asks the server about the version of ircd that it's running. Takes one
optional argument: a server name to query. If not supplied, defaults
to current server.

=item who

Lists the logged-on users matching a particular channel name, hostname,
nickname, or what-have-you. Takes one optional argument: a string for
it to search for. Wildcards are allowed; in the absence of this
argument, it will return everyone who's currently logged in (bad
move). Tack an "o" on the end if you want to list only IRCops, as per
the RFC.

=item whois

Queries the IRC server for detailed information about a particular
user. Takes any number of arguments: nicknames or hostmasks to ask for
information about. As of version 3.2, you will receive an 'irc_whois'
event in addition to the usual numeric responses. See below for details.

=item whowas

Asks the server for information about nickname which is no longer
connected. Takes at least one argument: a nickname to look up (no
wildcards allowed), the optional maximum number of history entries to
return, and the optional server hostname to query. As of version 3.2,
you will receive an 'irc_whowas' event in addition to the usual numeric
responses. See below for details.

=item ping/pong

Included for completeness sake. The component will deal with ponging to
pings automatically. Don't worry about it.

=back

=head2 Purely Esoteric Commands

=over

=item locops

Opers-only command. This one sends a message to all currently
logged-on local-opers (+l).  This option is specific to EFNet.

=item oper

In the exceedingly unlikely event that you happen to be an IRC
operator, you can use this command to authenticate with your IRC
server. Takes 2 arguments: your username and your password.

=item operwall

Opers-only command. This one sends a message to all currently
logged-on global opers.  This option is specific to EFNet.

=item rehash

Tells the IRC server you're connected to, to rehash its configuration
files. Only useful for IRCops. Takes no arguments.

=item die

Tells the IRC server you're connect to, to terminate. Only useful for
IRCops, thank goodness. Takes no arguments. 

=item restart

Tells the IRC server you're connected to, to shut down and restart itself.
Only useful for IRCops, thank goodness. Takes no arguments.

=item sconnect

Tells one IRC server (which you have operator status on) to connect to
another. This is actually the CONNECT command, but I already had an
event called 'connect', so too bad. Takes the args you'd expect: a
server to connect to, an optional port to connect on, and an optional
remote server to connect with, instead of the one you're currently on.

=item summon

Don't even ask.

=item wallops

Another opers-only command. This one sends a message to all currently
logged-on opers (and +w users); sort of a mass PA system for the IRC
server administrators. Takes one argument: some clever, witty message
to send.

=back

=head1 OUTPUT

The events you will receive (or can ask to receive) from your running
IRC component. Note that all incoming event names your session will
receive are prefixed by "irc_", to inhibit event namespace pollution.

If you wish, you can ask the client to send you every event it
generates. Simply register for the event name "all". This is a lot
easier than writing a huge list of things you specifically want to
listen for. FIXME: I'd really like to classify these somewhat
("basic", "oper", "ctcp", "dcc", "raw" or some such), and I'd welcome
suggestions for ways to make this easier on the user, if you can think
of some.

In your event handlers, $_[SENDER] is the particular component session that
sent you the event. $_[SENDER]->get_heap() will retrieve the component's 
object. Useful if you want on-the-fly access to the object and it's methods.

=head2 Important Events

=over

=item irc_connected

The IRC component will send an "irc_connected" event as soon as it
establishes a connection to an IRC server, before attempting to log
in. ARG0 is the server name.

B<NOTE:> When you get an "irc_connected" event, this doesn't mean you
can start sending commands to the server yet. Wait until you receive
an irc_001 event (the server welcome message) before actually sending
anything back to the server.

=item irc_ctcp

irc_ctcp events are generated upon receipt of CTCP messages, in addition to
the irc_ctcp_* events mentioned below.  They are identical in every way to
these, with one difference: instead of the * being in the method name, it
is prepended to the argument list.  For example, if someone types C</ctcp
Flibble foo bar>, an irc_ctcp event will be sent with C<foo> as ARG0,
and the rest as given below.

It is not recommended that you register for both irc_ctcp and irc_ctcp_*
events, since they will both be fired and presumably cause duplication.

=item irc_ctcp_*

irc_ctcp_whatever events are generated upon receipt of CTCP messages.
For instance, receiving a CTCP PING request generates an irc_ctcp_ping
event, CTCP ACTION (produced by typing "/me" in most IRC clients)
generates an irc_ctcp_action event, blah blah, so on and so forth. ARG0
is the nick!hostmask of the sender. ARG1 is the channel/recipient
name(s). ARG2 is the text of the CTCP message.

Note that DCCs are handled separately -- see the 'irc_dcc_request'
event, below.

=item irc_ctcpreply_*

irc_ctcpreply_whatever messages are just like irc_ctcp_whatever
messages, described above, except that they're generated when a response
to one of your CTCP queries comes back. They have the same arguments and
such as irc_ctcp_* events.

=item irc_disconnected

The counterpart to irc_connected, sent whenever a socket connection
to an IRC server closes down (whether intentionally or
unintentionally). ARG0 is the server name.

=item irc_error

You get this whenever the server sends you an ERROR message. Expect
this to usually be accompanied by the sudden dropping of your
connection. ARG0 is the server's explanation of the error.

=item irc_join

Sent whenever someone joins a channel that you're on. ARG0 is the
person's nick!hostmask. ARG1 is the channel name.

=item irc_invite

Sent whenever someone offers you an invitation to another channel. ARG0
is the person's nick!hostmask. ARG1 is the name of the channel they want
you to join.

=item irc_kick

Sent whenever someone gets booted off a channel that you're on. ARG0
is the kicker's nick!hostmask. ARG1 is the channel name. ARG2 is the
nick of the unfortunate kickee. ARG3 is the explanation string for the
kick.

=item irc_mode

Sent whenever someone changes a channel mode in your presence, or when
you change your own user mode. ARG0 is the nick!hostmask of that
someone. ARG1 is the channel it affects (or your nick, if it's a user
mode change). ARG2 is the mode string (i.e., "+o-b"). The rest of the
args (ARG3 .. $#_) are the operands to the mode string (nicks,
hostmasks, channel keys, whatever).

=item irc_msg

Sent whenever you receive a PRIVMSG command that was addressed to you
privately. ARG0 is the nick!hostmask of the sender. ARG1 is an array
reference containing the nick(s) of the recipients. ARG2 is the text
of the message.

=item irc_nick

Sent whenever you, or someone around you, changes nicks. ARG0 is the
nick!hostmask of the changer. ARG1 is the new nick that they changed
to.

=item irc_notice

Sent whenever you receive a NOTICE command. ARG0 is the nick!hostmask
of the sender. ARG1 is an array reference containing the nick(s) or
channel name(s) of the recipients. ARG2 is the text of the NOTICE
message.

=item irc_part

Sent whenever someone leaves a channel that you're on. ARG0 is the
person's nick!hostmask. ARG1 is the channel name. ARG2 is the part message.

=item irc_ping

An event sent whenever the server sends a PING query to the
client. (Don't confuse this with a CTCP PING, which is another beast
entirely. If unclear, read the RFC.) Note that POE::Component::IRC will
automatically take care of sending the PONG response back to the
server for you, although you can still register to catch the event for
informational purposes.

=item irc_public

Sent whenever you receive a PRIVMSG command that was sent to a
channel. ARG0 is the nick!hostmask of the sender. ARG1 is an array
reference containing the channel name(s) of the recipients. ARG2 is
the text of the message.

=item irc_quit

Sent whenever someone on a channel with you quits IRC (or gets
KILLed). ARG0 is the nick!hostmask of the person in question. ARG1 is
the clever, witty message they left behind on the way out.

=item irc_socketerr

Sent when a connection couldn't be established to the IRC server. ARG0
is probably some vague and/or misleading reason for what failed.

=item irc_topic

Sent when a channel topic is set or unset. ARG0 is the nick!hostmask of the sender. ARG1 is the channel affected. ARG2 will be either: a string if the topic is being set; or a zero-length string (ie. '') if the topic is being unset. Note: replies to queries about what a channel topic *is* (ie. TOPIC #channel) , are returned as numerics, not with this event.


=item irc_whois

Sent in response to a 'whois' query. ARG0 is a hashref, with the following
keys: 

  'nick', the users nickname; 
  'user', the users username; 
  'host', their hostname;
  'real', their real name;
  'idle', their idle time in seconds;
  'signon', the epoch time they signed on ( will be undef if ircd does not support this );
  'channels', an arrayref listing visible channels they are on, the channel is prefixed
              with '@','+','%' depending on whether they have +o +v or +h;
  'server', their server ( might not be useful on some networks );
  'oper', whether they are an IRCop, contains the IRC operator string if they are, 
          undef if they aren't.
  'actually', some ircds report the users actual ip address, that'll be here;

On Freenode if the user has identified with NICKSERV there will be an additional key:

  'identified'.

=item irc_whowas

Similar to the above, except some keys will be missing.

=item irc_raw

Enabled by passing 'Raw' => 1 to spawn() or connect(), ARG0 is the raw IRC string received
by the component from the IRC server, before it has been mangled by filters and such like.

=item irc_registered

Sent once to the requesting session on registration ( see register() ). ARG0 is a reference to
the component's object.

=item irc_shutdown

Sent to all registered sessions when the component has been asked to shutdown(). ARG0 will be the session ID of the requesting session.

=item irc_isupport

Emitted by the first event after an irc_005, to indicate that isupport information has been gathered. ARG0 is the L<POE::Component::IRC::Plugin::ISupport|POE::Component::IRC::Plugin::ISupport> object.

=item irc_delay_set

Emitted on a succesful addition of a delayed event using delay() method. ARG0 will be the
alarm_id which can be used later with delay_remove(). Subsequent parameters are the arguments that were passed to delay().

=item irc_delay_removed

Emitted when a delayed command is successfully removed. ARG0 will be the alarm_id that was removed. 
Subsequent parameters are the arguments that were passed to delay().

=item irc_socks_failed

Emitted whenever we fail to connect successfully to a SOCKS server or the SOCKS server is not actually a SOCKS
server. ARG0 will be some vague reason as to what went wrong. Hopefully.

=item irc_socks_rejected

Emitted whenever a SOCKS connection is rejected by a SOCKS server. ARG0 is the SOCKS code, ARG1 the SOCKS server
address, ARG2 the SOCKS port and ARG3 the SOCKS user id ( if defined ).

=item All numeric events (see RFC 1459)

Most messages from IRC servers are identified only by three-digit
numeric codes with undescriptive constant names like RPL_UMODEIS and
ERR_NOTOPLEVEL. (Actually, the list of codes in the RFC is kind of
out-of-date... the list in the back of Net::IRC::Event.pm is more
complete, and different IRC networks have different and incompatible
lists. Ack!) As an example, say you wanted to handle event 376
(RPL_ENDOFMOTD, which signals the end of the MOTD message). You'd
register for '376', and listen for 'irc_376' events. Simple, no? ARG0
is the name of the server which sent the message. ARG1 is the text of
the message. ARG2 is an ARRAYREF of the parsed message, so there is no
need to parse ARG1 yourself.

=back

=head2 Somewhat Less Important Events

=over

=item irc_dcc_chat

Notifies you that one line of text has been received from the
client on the other end of a DCC CHAT connection. ARG0 is the
connection's magic cookie, ARG1 is the nick of the person on the other
end, ARG2 is the port number, and ARG3 is the text they sent.

=item irc_dcc_done

You receive this event when a DCC connection terminates normally.
Abnormal terminations are reported by "irc_dcc_error", below. ARG0 is
the connection's magic cookie, ARG1 is the nick of the person on the
other end, ARG2 is the DCC type (CHAT, SEND, GET, etc.), and ARG3 is the
port number. For DCC SEND and GET connections, ARG4 will be the
filename, ARG5 will be the file size, and ARG6 will be the number of
bytes transferred. (ARG5 and ARG6 should always be the same.)

=item irc_dcc_failed

You get this event when a DCC connection fails for some reason. ARG0 
will be the operation that failed, ARG1 is the error number, ARG2 is
the description of the error and ARG3 the connection's magic cookie.

=item irc_dcc_error

You get this event whenever a DCC connection or connection attempt
terminates unexpectedly or suffers some fatal error. ARG0 will be the
connection's magic cookie, ARG1 will be a string describing the error.
ARG2 will be the nick of the person on the other end of the connection.
ARG3 is the DCC type (SEND, GET, CHAT, etc.). ARG4 is the port number of
the DCC connection, if any. For SEND and GET connections, ARG5 is the
filename, ARG6 is the expected file size, and ARG7 is the transfered size.

=item irc_dcc_get

Notifies you that another block of data has been successfully
transferred from the client on the other end of your DCC GET connection.
ARG0 is the connection's magic cookie, ARG1 is the nick of the person on
the other end, ARG2 is the port number, ARG3 is the filename, ARG4 is
the total file size, and ARG5 is the number of bytes successfully
transferred so far.

=item irc_dcc_request

You receive this event when another IRC client sends you a DCC SEND or
CHAT request out of the blue. You can examine the request and decide
whether or not to accept it here. ARG0 is the nick of the client on the
other end. ARG1 is the type of DCC request (CHAT, SEND, etc.). ARG2 is
the port number. ARG3 is a "magic cookie" argument, suitable for sending
with 'dcc_accept' events to signify that you want to accept the
connection (see the 'dcc_accept' docs). For DCC SEND and GET
connections, ARG4 will be the filename, and ARG5 will be the file size.

=item irc_dcc_send

Notifies you that another block of data has been successfully
transferred from you to the client on the other end of a DCC SEND
connection. ARG0 is the connection's magic cookie, ARG1 is the nick of
the person on the other end, ARG2 is the port number, ARG3 is the
filename, ARG4 is the total file size, and ARG5 is the number of bytes
successfully transferred so far.

=item irc_dcc_start

This event notifies you that a DCC connection has been successfully
established. ARG0 is a unique "magic cookie" argument which you can pass
to 'dcc_chat' or 'dcc_close'. ARG1 is the nick of the person on the
other end, ARG2 is the DCC type (CHAT, SEND, GET, etc.), and ARG3 is the
port number. For DCC SEND and GET connections, ARG4 will be the filename
and ARG5 will be the file size.

=item irc_snotice

A weird, non-RFC-compliant message from an IRC server. Don't worry
about it. ARG0 is the text of the server's message.

=item dcc_resume

  bboetts puny try to get dcc resume implemented in this great
  module:
  ARG0 is the well known 'magic cookie' (as in dcc_send etc.)
  ARG1 is the (eventually new) name of the file
  ARG2 is the size from which will be resumed

  usage and example:

  sub irc_dcc_request {
    my ($kernel, $nick, $type, $port, $magic, $filename, $size) =
      @_[KERNEL, ARG0 .. ARG5];

    print "DCC $type request from $nick on port $port\n";
    if($args->{type} =~ /SEND/i)
    {
      $nick = ($nick =~ /^([^!]+)/);
      $nick =~ s/\W//;
      if(my $filesize = -s "$1.$filename")
      {
	$kernel->post('test', 'dcc_resume', $magic, "$1.$filename", "$filesize" );
	#dont forget to save the cookie, it holds the address of the counterpart which won't be in the server response!!
	$args->{heap}->{cookies}->{$args->{file}} = $args->{magic};
      }#if(-s "$1.$filename")
      else
      {
	$kernel->post( 'test', 'dcc_accept', $magic, "$1.$filename" );
      }#else
    }
  elsif($args->{type} =~ /ACCEPT/i)
  {
      $kernel->post( $args->{context}, 'dcc_accept', $magic, $filename);
  }
  }
 you need a counter part in irc_dcc_request:

    if($type eq 'ACCEPT')
    {
       #the args are in wrong order and missing shift the args 1 up
       $magic->{port} = $magic->{addr};

       my $altcookie = $_[OBJECT]->{cookies}->{$filename};
       $magic->{addr} = $altcookie->{addr};
       delete $_[OBJECT]->{cookies}->{$filename};
       #TODO beware a possible memory leak here...
    }# if($type eq 'ACCEPT')

=back

=head1 SIGNALS

The component will handle a number of custom signals that you may send using 
L<POE::Kernel> signal() method.

=over

=item POCOIRC_REGISTER

Registering with multiple PoCo-IRC components has been a pita. Well, no more,
using the power of L<POE::Kernel> signals.

If the component receives a 'POCOIRC_REGISTER' signal it'll register the requesting
session and trigger an 'irc_registered' event. From that event one can get all the 
information necessary such as the poco-irc object and the SENDER session to do 
whatever one needs to build a poco-irc dispatch table.

The way the signal handler in PoCo-IRC is written also supports sending the 
'POCOIRC_REGISTER' to multiple sessions simultaneously, by sending the signal to the 
POE Kernel itself.

Pass the signal your session, session ID or alias, and the IRC events ( as specified
to 'register' ).

To register with multiple PoCo-IRCs one can do the following in your session's _start
handler:

  sub _start {
     my ($kernel,$session) = @_[KERNEL,SESSION];

     # Registering with multiple pocoircs for 'all' IRC events
     $kernel->signal( $kernel, 'POCOIRC_REGISTER', $session->ID(), 'all' );

     undef;
  }

Each poco-irc will send your session an 'irc_registered' event:

  sub irc_registered {
     my ($kernel,$sender,$heap,$irc_object) = @_[KERNEL,SENDER,HEAP,ARG0];
     
     # Get the poco-irc session ID 
     my $sender_id = $sender->ID();
     
     # Or it's alias
     my $poco_alias = $irc_object->session_alias();

     # Store it in our heap maybe
     $heap->{irc_objects}->{ $sender_id } = $irc_object;

     # Make the poco connect 
     $irc_object->yield( connect => { } );

     undef;
  }

=item POCOIRC_SHUTDOWN

Telling multiple poco-ircs to shutdown was a pita as well. The same principle as
with registering applies to shutdown too.

Send a 'POCOIRC_SHUTDOWN' to the POE Kernel to terminate all the active poco-ircs
simultaneously.

  $poe_kernel->signal( $poe_kernel, 'POCOIRC_SHUTDOWN' );

Any additional parameters passed to the signal will become your quit messages on 
each IRC network.

=back

=head1 BUGS

A few have turned up in the past and they are sure to again. Please use
L<http://rt.cpan.org/> to report any. Alternatively, email the current maintainer.

=head1 MAINTAINER

Chris 'BinGOs' Williams E<lt>chris@bingosnet.co.ukE<gt>

=head1 AUTHOR

Dennis Taylor.

=head1 LICENCE

Copyright (c) Dennis Taylor and Chris Williams

This module may be used, modified, and distributed under the same
terms as Perl itself. Please see the license that came with your Perl
distribution for details.

=head1 MAD PROPS

The maddest of mad props go out to Rocco "dngor" Caputo
E<lt>troc@netrus.netE<gt>, for inventing something as mind-bogglingly
cool as POE, and to Kevin "oznoid" Lenzo E<lt>lenzo@cs.cmu.eduE<gt>,
for being the attentive parent of our precocious little infobot on
#perl.

Further props to a few of the studly bughunters who made this module not
suck: Abys <abys@web1-2-3.com>, Addi <addi@umich.edu>, ResDev
<ben@reser.org>, and Roderick <roderick@argon.org>. Woohoo!

Kudos to Apocalypse, <apocal@cpan.org>, for the plugin system and to
Jeff 'japhy' Pinyan, <japhy@perlmonk.org>, for Pipeline.

Thanks to the merry band of POE pixies from #PoE @ irc.perl.org,
including ( but not limited to ), ketas, ct, dec, integral, webfox,
immute, perigrin, paulv, alias.

Check out the Changes file for further contributors.

=head1 SEE ALSO

RFC 1459 L<http://www.faqs.org/rfcs/rfc1459.html> 

L<http://www.irchelp.org/>,

L<http://poe.perl.org/>,

L<http://www.infobot.org/>,

Some good examples reside in the POE cookbook which has a whole section devoted to
IRC programming L<http://poe.perl.org/?POE_Cookbook>.

The examples/ folder of this distribution.

=cut
