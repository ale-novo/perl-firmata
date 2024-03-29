package Device::Firmata::Protocol;

=head1 NAME

Device::Firmata::Protocol - Firmata protocol implementation

=cut

use strict;
use warnings;
use vars qw/ $MIDI_DATA_SIZES /;
use POSIX;

use constant {
  MIDI_COMMAND                => 0x80,
  MIDI_PARSE_NORMAL           => 0,
  MIDI_PARSE_SYSEX            => 1,
  MIDI_START_SYSEX            => 0xf0,
  MIDI_END_SYSEX              => 0xf7,
  MAX_PROTOCOL_VERSION        => 'V_2_06',  # highest Firmata protocol version currently implemented
};

use Device::Firmata::Constants qw/ :all /;
use Device::Firmata::Base
  ISA                         => 'Device::Firmata::Base',
  FIRMATA_ATTRIBS             => {
  buffer                      => [],
  parse_status                => MIDI_PARSE_NORMAL,
  protocol_version            => MAX_PROTOCOL_VERSION, # We are starting with the highest protocol
  };

$MIDI_DATA_SIZES = {
  0x80                        => 2,
  0x90                        => 2,
  0xA0                        => 2,
  0xB0                        => 2,
  0xC0                        => 1,
  0xD0                        => 1,
  0xE0                        => 2,
  0xF0                        => 0,    # note that this requires special handling

  # Special for version queries
  0xF4                        => 2,
  0xF9                        => 2,
  0x71                        => 0,
  0xFF                        => 0,
};

our $ONE_WIRE_COMMANDS = {
  SEARCH_REQUEST              => 0x40,
  CONFIG_REQUEST              => 0x41,
  SEARCH_REPLY                => 0x42,
  READ_REPLY                  => 0x43,
  SEARCH_ALARMS_REQUEST       => 0x44,
  SEARCH_ALARMS_REPLY         => 0x45,
  RESET_REQUEST_BIT           => 0x01,
  SKIP_REQUEST_BIT            => 0x02,
  SELECT_REQUEST_BIT          => 0x04,
  READ_REQUEST_BIT            => 0x08,
  DELAY_REQUEST_BIT           => 0x10,
  WRITE_REQUEST_BIT           => 0x20,
};

our $SCHEDULER_COMMANDS = {
  CREATE_FIRMATA_TASK         => 0,
  DELETE_FIRMATA_TASK         => 1,
  ADD_TO_FIRMATA_TASK         => 2,
  DELAY_FIRMATA_TASK          => 3,
  SCHEDULE_FIRMATA_TASK       => 4,
  QUERY_ALL_FIRMATA_TASKS     => 5,
  QUERY_FIRMATA_TASK          => 6,
  RESET_FIRMATA_TASKS         => 7,
  ERROR_TASK_REPLY            => 8,
  QUERY_ALL_TASKS_REPLY       => 9,
  QUERY_TASK_REPLY            => 10,
};

our $STEPPER_COMMANDS = {
  STEPPER_CONFIG              => 0,
  STEPPER_STEP                => 1,
};

our $STEPPER_INTERFACES = {
  DRIVER                      => 1,
  TWO_WIRE                    => 2,
  FOUR_WIRE                   => 4,
};

our $ACCELSTEPPER_COMMANDS = {
  STEPPER_CONFIG              => 0,
  STEPPER_ZERO                => 1,
  STEPPER_STEP                => 2,
  STEPPER_TO                  => 3,
  STEPPER_ENABLE              => 4,
  STEPPER_STOP                => 5,
  STEPPER_REPORT              => 6,
  STEPPER_LIMIT               => 7,
  STEPPER_ACCEL               => 8,
  STEPPER_SPEED               => 9,
  STEPPER_MOVE                => 0x0A,
  STEPPER_MULTICONFIG         => 0x20,
  STEPPER_MULTITO             => 0x21,
  STEPPER_MULTISTOP           => 0x23,
  STEPPER_MULTIMOVE           => 0x24,

};

our $ACCELSTEPPER_INTERFACES = {
  DRIVER                      => 1,
  TWO_WIRE                    => 2,
  THREE_WIRE                  => 3,
  FOUR_WIRE                   => 4,
};

our $ACCELSTEPPER_STEP = {
  WHOLE                       => 0,
  HALF                        => 1,
  QUARTER                     => 2,
};

our $ENCODER_COMMANDS = {
  ENCODER_ATTACH              => 0,
  ENCODER_REPORT_POSITION     => 1,
  ENCODER_REPORT_POSITIONS    => 2,
  ENCODER_RESET_POSITION      => 3,
  ENCODER_REPORT_AUTO         => 4,
  ENCODER_DETACH              => 5,
};

our $SERIAL_COMMANDS = {
  SERIAL_CONFIG            => 0x10, # config serial port stetting such as baud rate and pins
  SERIAL_WRITE             => 0x20, # write to serial port
  SERIAL_READ              => 0x30, # read request to serial port
  SERIAL_REPLY             => 0x40, # read reply from serial port
  SERIAL_LISTEN            => 0x70, # start listening on software serial port
};

our $MODENAMES = {
  0                           => 'INPUT',
  1                           => 'OUTPUT',
  2                           => 'ANALOG',
  3                           => 'PWM',
  4                           => 'SERVO',
  5                           => 'SHIFT',
  6                           => 'I2C',
  7                           => 'ONEWIRE',
  8                           => 'STEPPER',
  9                           => 'ENCODER',
 10                           => 'SERIAL',
 11                           => 'PULLUP',
};

=head1 DESCRIPTION

Implementation of the Firmata 2.5 protocol specification.

Because we're dealing with a permutation of the
MIDI protocol, certain commands are one byte,
others 2 or even 3. We do this part to figure out
how many bytes we're actually looking at

One of the first things to know is that while
MIDI is packet based, the bytes have specialized
construction (where the top-most bit has been
reserved to differentiate if it's a command or a
data bit)

So any byte being transferred in a MIDI stream
will look like the following

 BIT# | 7 | 6 | 5 | 4 | 3 | 2 | 1 | 0 |
 DATA | X | ? | ? | ? | ? | ? | ? | ? |

If X is a "1" this byte is considered a command byte
If X is a "0" this byte is considered a data bte

We figure out how many bytes a packet is by looking at the
command byte and of that byte, only the high nibble.
This nibble tells us the requisite information via a lookup
table...

See: http://www.midi.org/techspecs/midimessages.php
And
http://www.ccarh.org/courses/253/handout/midiprotocol/
For more information

Basically, however:

command
nibble  bytes
8       2
9       2
A       2
B       2
C       1
D       1
E       2
F       0 or variable

=head1 METHODS

=head2 message_data_receive

Receive a string of data. Normally, only one byte
is passed due to the code, but you can also pass as
many bytes in a string as you'd like.

=cut

sub message_data_receive {

  # --------------------------------------------------
  my ( $self, $data ) = @_;

  defined $data and length $data or return;

  my $protocol_version  = $self->{protocol_version};
  my $protocol_commands = $COMMANDS->{$protocol_version};
  my $protocol_lookup   = $COMMAND_LOOKUP->{$protocol_version};

  # Add the new data to the buffer
  my $buffer = $self->{buffer} ||= [];
  push @$buffer, unpack "C*", $data;

  my @packets;

  # Loop until we're finished parsing all available packets
  while (@$buffer) {
    # Not in SYSEX mode, we can proceed normally
    if (    $self->{parse_status} == MIDI_PARSE_NORMAL and $buffer->[0] == MIDI_START_SYSEX ) {
      my $command = shift @$buffer;
      push @packets, {
          command     => $command,
          command_str => $protocol_lookup->{$command} || 'START_SYSEX',
        };
      $self->{parse_status} = MIDI_PARSE_SYSEX;
      next;
    }
    # If in sysex mode, we will check for the end of the sysex message here
    elsif ( $self->{parse_status} == MIDI_PARSE_SYSEX and $buffer->[0] == MIDI_END_SYSEX ) {
      $self->{parse_status} = MIDI_PARSE_NORMAL;
      my $command = shift @$buffer;
      push @packets, {
          command     => $command,
          command_str => $protocol_lookup->{$command} || 'END_SYSEX',
        };
    }

# Regardless of the SYSEX mode we are in, we will allow commands to interrupt the flowthrough
    elsif ( $buffer->[0] & MIDI_COMMAND ) {
      my $command = $buffer->[0] & 0xf0;
      my $bytes = ( $MIDI_DATA_SIZES->{$command} || $MIDI_DATA_SIZES->{ $buffer->[0] } ) + 1;
      last if ( @$buffer < $bytes );
      my @data = splice @$buffer, 0, $bytes;
      $command = shift @data;
      push @packets,
        {
          command     => $command,
          command_str => $protocol_lookup->{$command}
            || $protocol_lookup->{ $command & 0xf0 }
            || 'UNKNOWN',
            data => \@data
        };
    }

# We have a data byte, if we're in SYSEX mode, we'll just add that to the data stream
# packet
    elsif ( $self->{parse_status} == MIDI_PARSE_SYSEX ) {
      my $data = shift @$buffer;
      if ( @packets and $packets[-1]{command_str} eq 'DATA_SYSEX' ) {
        push @{ $packets[-1]{data} }, $data;
      }
      else {
        push @packets,
          {
            command     => 0x0,
            command_str => 'DATA_SYSEX',
            data        => [$data]
          };
      }

    }

    # No idea what to do with this one, eject it and skip to the next
    else {
      shift @$buffer;
      last if ( not @$buffer );
    }
  }

  return if not @packets;
  return \@packets;
}

=head2 sysex_parse

Takes the sysex data buffer and parses it into
something useful

=cut

sub sysex_parse {

  # --------------------------------------------------
  my ( $self, $sysex_data ) = @_;

  my $protocol_version  = $self->{protocol_version};
  my $protocol_commands = $COMMANDS->{$protocol_version};
  my $protocol_lookup   = $COMMAND_LOOKUP->{$protocol_version};

  my $command = shift @$sysex_data;
  if ( defined $command ) {
    my $command_str = $protocol_lookup->{$command};

    if ($command_str) {
      my $return_data;

      COMMAND_HANDLER: {

        $command == $protocol_commands->{STRING_DATA} and do {
          $return_data = $self->handle_string_data($sysex_data);
          last;
        };

        $command == $protocol_commands->{REPORT_FIRMWARE} and do {
          $return_data = $self->handle_report_firmware($sysex_data);
          last;
        };

        $command == $protocol_commands->{CAPABILITY_RESPONSE} and do {
          $return_data = $self->handle_capability_response($sysex_data);
          last;
        };

        $command == $protocol_commands->{ANALOG_MAPPING_RESPONSE} and do {
          $return_data =
            $self->handle_analog_mapping_response($sysex_data);
          last;
        };

        $command == $protocol_commands->{PIN_STATE_RESPONSE} and do {
          $return_data = $self->handle_pin_state_response($sysex_data);
          last;
        };

        $command == $protocol_commands->{I2C_REPLY} and do {
          $return_data = $self->handle_i2c_reply($sysex_data);
          last;
        };

        $command == $protocol_commands->{ONEWIRE_DATA} and do {
          $return_data = $self->handle_onewire_reply($sysex_data);
          last;
        };

        $command == $protocol_commands->{SCHEDULER_DATA} and do {
          $return_data = $self->handle_scheduler_response($sysex_data);
          last;
        };

        $command == $protocol_commands->{STEPPER_DATA} and do {
          $return_data = $self->handle_stepper_response($sysex_data);
          last;
        };

        $command == $protocol_commands->{ACCELSTEPPER_DATA} and do {
          $return_data = $self->handle_accelstepper_response($sysex_data);
          last;
        };

        $command == $protocol_commands->{ENCODER_DATA} and do {
          $return_data = $self->handle_encoder_response($sysex_data);
          last;
        };

        $command == $protocol_commands->{SERIAL_DATA} and do {
          $return_data = $self->handle_serial_reply($sysex_data);
          last;
        };

        $command == $protocol_commands->{RESERVED_COMMAND} and do {
          $return_data = $sysex_data;
          last;
        };
      }

      return {
        command     => $command,
        command_str => $command_str,
        data        => $return_data
      };
    } else {
      return {
        command     => $command,
        data        => $sysex_data
      }
    }
  }
  return undef;
}

=head2 message_prepare

Using the midi protocol, create a binary packet
that can be transmitted to the serial output

=cut

sub message_prepare {

  # --------------------------------------------------
  my ( $self, $command_name, $channel, @data ) = @_;

  my $protocol_version  = $self->{protocol_version};
  my $protocol_commands = $COMMANDS->{$protocol_version};
  my $command           = $protocol_commands->{$command_name} or return;

  my $bytes = 1 +
    ( $MIDI_DATA_SIZES->{ $command & 0xf0 } || $MIDI_DATA_SIZES->{$command} );
  my $packet = pack "C" x $bytes, $command | $channel, @data;
  return $packet;
}

=head2 packet_sysex

create a binary packet containing a sysex-message

=cut

sub packet_sysex {

  my ( $self, @sysex_data ) = @_;

  my $protocol_version  = $self->{protocol_version};
  my $protocol_commands = $COMMANDS->{$protocol_version};
  
  my $bytes = @sysex_data + 2;
  my $packet = pack "C" x $bytes, $protocol_commands->{START_SYSEX},
    @sysex_data,
    $protocol_commands->{END_SYSEX};
  return $packet;
}

=head2 packet_sysex_command

create a binary packet containing a sysex-command

=cut

sub packet_sysex_command {

  my ( $self, $command_name, @data ) = @_;

  my $protocol_version  = $self->{protocol_version};
  my $protocol_commands = $COMMANDS->{$protocol_version};
  my $command           = $protocol_commands->{$command_name} or return;

#    my $bytes = 3+($MIDI_DATA_SIZES->{$command & 0xf0}||$MIDI_DATA_SIZES->{$command});
  my $bytes = @data + 3;
  my $packet = pack "C" x $bytes, $protocol_commands->{START_SYSEX},
    $command,
    @data,
    $protocol_commands->{END_SYSEX};
  return $packet;
}

=head2 packet_query_version

Craft a firmware version query packet to be sent

=cut

sub packet_query_version {
  my $self = shift;
  return $self->message_prepare( REPORT_VERSION => 0 );

}

sub handle_query_version_response {
  my ( $self, $data ) = @_;
  return {
      major_version => shift @$data,
      minor_version => shift @$data,
    };
}

sub handle_string_data {
  my ( $self, $sysex_data ) = @_;
  return { string => double_7bit_to_string($sysex_data) };
}

=head2 packet_query_firmware

Craft a firmware variant query packet to be sent

=cut

sub packet_query_firmware {
  my $self = shift;
  return $self->packet_sysex_command(REPORT_FIRMWARE);
}

sub handle_report_firmware {
  my ( $self, $sysex_data ) = @_;
  return {
      major_version => shift @$sysex_data,
      minor_version => shift @$sysex_data,
      firmware      => double_7bit_to_string($sysex_data)
    };
}

sub packet_query_capability {
  my $self = shift;
  return $self->packet_sysex_command(CAPABILITY_QUERY);
}

#/* capabilities response
# * -------------------------------
# * 0  START_SYSEX (0xF0) (MIDI System Exclusive)
# * 1  capabilities response (0x6C)
# * 2  1st mode supported of pin 0
# * 3  1st mode's resolution of pin 0
# * 4  2nd mode supported of pin 0
# * 5  2nd mode's resolution of pin 0
# ...   additional modes/resolutions, followed by a single 127 to mark the
#       end of the first pin's modes.  Each pin follows with its mode and
#       127, until all pins implemented.
# * N  END_SYSEX (0xF7)
# */

sub handle_capability_response {
  my ( $self, $sysex_data ) = @_;
  my %capabilities;
  my $byte = shift @$sysex_data;
  my $i=0;
  while ( defined $byte ) {
    my %pinmodes;
    while ( defined $byte && $byte != 127 ) {
      $pinmodes{$byte} = {
        mode_str   => $MODENAMES->{$byte},
        resolution => shift @$sysex_data    # /secondbyte
      };
      $byte = shift @$sysex_data;
    }
    $capabilities{$i}=\%pinmodes;
    $i++;
    $byte = shift @$sysex_data;
  }
  return { capabilities => \%capabilities };
}

sub packet_query_analog_mapping {
  my $self = shift;
  return $self->packet_sysex_command(ANALOG_MAPPING_QUERY);
}

#/* analog mapping response
# * -------------------------------
# * 0  START_SYSEX (0xF0) (MIDI System Exclusive)
# * 1  analog mapping response (0x6A)
# * 2  analog channel corresponding to pin 0, or 127 if pin 0 does not support analog
# * 3  analog channel corresponding to pin 1, or 127 if pin 1 does not support analog
# * 4  analog channel corresponding to pin 2, or 127 if pin 2 does not support analog
# ...   etc, one byte for each pin
# * N  END_SYSEX (0xF7)
# */

sub handle_analog_mapping_response {
  my ( $self, $sysex_data ) = @_;
  my %pins;
  my $pin_mapping = shift @$sysex_data;
  my $i=0;

  while ( defined $pin_mapping ) {
    $pins{$pin_mapping}=$i if ($pin_mapping!=127);
    $pin_mapping = shift @$sysex_data;
    $i++;
  }
  return { mappings => \%pins };
}

#/* pin state query
# * -------------------------------
# * 0  START_SYSEX (0xF0) (MIDI System Exclusive)
# * 1  pin state query (0x6D)
# * 2  pin (0 to 127)
# * 3  END_SYSEX (0xF7) (MIDI End of SysEx - EOX)
# */

sub packet_query_pin_state {
  my ( $self, $pin ) = @_;
  return $self->packet_sysex_command( PIN_STATE_QUERY, $pin );
}

#/* pin state response
# * -------------------------------
# * 0  START_SYSEX (0xF0) (MIDI System Exclusive)
# * 1  pin state response (0x6E)
# * 2  pin (0 to 127)
# * 3  pin mode (the currently configured mode)
# * 4  pin state, bits 0-6
# * 5  (optional) pin state, bits 7-13
# * 6  (optional) pin state, bits 14-20
# ...  additional optional bytes, as many as needed
# * N  END_SYSEX (0xF7)
# */

sub handle_pin_state_response {
  my ( $self, $sysex_data ) = @_;
  my $pin    = shift @$sysex_data;
  my $mode   = shift @$sysex_data;
  my $state  = shift @$sysex_data & 0x7f;
  my $nibble = shift @$sysex_data;
  for ( my $i = 1 ; defined $nibble ; $nibble = shift @$sysex_data ) {
    $state += ( $nibble & 0x7f ) << ( 7 * $i );
  }

  return {
    pin       => $pin,
    mode      => $mode,
    moden_str => $MODENAMES->{$mode},
    state     => $state
  };

}

sub packet_sampling_interval {
  my ( $self, $interval ) = @_;
  return $self->packet_sysex_command( SAMPLING_INTERVAL,
    $interval & 0x7f,
    $interval >> 7
  );
}

#/* I2C read/write request
# * -------------------------------
# * 0  START_SYSEX (0xF0) (MIDI System Exclusive)
# * 1  I2C_REQUEST (0x76)
# * 2  slave address (LSB)
# * 3  slave address (MSB) + read/write and address mode bits
#      {7: always 0} + {6: reserved} + {5: address mode, 1 means 10-bit mode} +
#      {4-3: read/write, 00 => write, 01 => read once, 10 => read continuously, 11 => stop reading} +
#      {2-0: slave address MSB in 10-bit mode, not used in 7-bit mode}
# * 4  data 0 (LSB)
# * 5  data 0 (MSB)
# * 6  data 1 (LSB)
# * 7  data 1 (MSB)
# * ...
# * n  END_SYSEX (0xF7)
# */

sub packet_i2c_request {
  my ( $self, $address, $command, @i2cdata ) = @_;
  if (($address & 0x380) > 0) {
    $command |= (0x20 | (($address >> 7) & 0x7));
  }

  if (scalar @i2cdata) {
    my @data;
    push_array_as_two_7bit(\@i2cdata,\@data);
    return $self->packet_sysex_command( I2C_REQUEST,
      $address & 0x7f,
      $command,
      @data,
    );
  } else {
    return $self->packet_sysex_command( I2C_REQUEST,
      $address & 0x7f,
      $command,
    );
  }
}

#/* I2C reply
# * -------------------------------
# * 0  START_SYSEX (0xF0) (MIDI System Exclusive)
# * 1  I2C_REPLY (0x77)
# * 2  slave address (LSB)
# * 3  slave address (MSB)
# * 4  register (LSB)
# * 5  register (MSB)
# * 6  data 0 LSB
# * 7  data 0 MSB
# * ...
# * n  END_SYSEX (0xF7)
# */

sub handle_i2c_reply {
  my ( $self, $sysex_data ) = @_;
  my $address = shift14bit($sysex_data);
  my $register = shift14bit($sysex_data);
  my @data = double_7bit_to_array($sysex_data);
  return {
    address       => $address,
    register      => $register,
    data          => \@data,
  };
}

#/* I2C config
# * -------------------------------
# * 0  START_SYSEX (0xF0) (MIDI System Exclusive)
# * 1  I2C_CONFIG (0x78)
# * 2  Delay in microseconds (LSB)
# * 3  Delay in microseconds (MSB)
# * ... user defined for special cases, etc
# * n  END_SYSEX (0xF7)
# */

sub packet_i2c_config {
  my ( $self, $delay, @data ) = @_;
  return $self->packet_sysex_command( I2C_CONFIG,
    $delay & 0x7f,
    $delay >> 7, @data
  );
}

#/* servo config
# * --------------------
# * 0  START_SYSEX (0xF0)
# * 1  SERVO_CONFIG (0x70)
# * 2  pin number (0-127)
# * 3  minPulse LSB (0-6)
# * 4  minPulse MSB (7-13)
# * 5  maxPulse LSB (0-6)
# * 6  maxPulse MSB (7-13)
# * 7  END_SYSEX (0xF7)
# */

sub packet_servo_config_request {
  my ( $self, $pin, $data ) = @_;
  my $min_pulse = $data->{min_pulse};
  my $max_pulse = $data->{max_pulse};

  return $self->packet_sysex_command( SERVO_CONFIG,
    $pin & 0x7f,
    $min_pulse & 0x7f,
    $min_pulse >> 7,
    $max_pulse & 0x7f,
    $max_pulse >> 7
  );
}

#This is just the standard SET_PIN_MODE message:

#/* set digital pin mode
# * --------------------
# * 1  set digital pin mode (0xF4) (MIDI Undefined)
# * 2  pin number (0-127)
# * 3  state (INPUT/OUTPUT/ANALOG/PWM/SERVO, 0/1/2/3/4)
# */

#Then the normal ANALOG_MESSAGE data format is used to send data.

#/* write to servo, servo write is performed if the pins mode is SERVO
# * ------------------------------
# * 0  ANALOG_MESSAGE (0xE0-0xEF)
# * 1  value lsb
# * 2  value msb
# */

sub packet_onewire_search_request {
  my ( $self, $pin ) = @_;
  return $self->packet_sysex_command( ONEWIRE_DATA,$ONE_WIRE_COMMANDS->{SEARCH_REQUEST},$pin);
};

sub packet_onewire_search_alarms_request {
  my ( $self, $pin ) = @_;
  return $self->packet_sysex_command( ONEWIRE_DATA,$ONE_WIRE_COMMANDS->{SEARCH_ALARMS_REQUEST},$pin);
};

sub packet_onewire_config_request {
  my ( $self, $pin, $power ) = @_;
  return $self->packet_sysex_command( ONEWIRE_DATA, $ONE_WIRE_COMMANDS->{CONFIG_REQUEST},$pin,
    ( defined $power ) ? $power : 1
  );
};

#$args = {
# reset => undef | 1,
# skip => undef | 1,
# select => undef | device,
# read => undef | short int,
# delay => undef | long int,
# write => undef | bytes[],
#}

sub packet_onewire_request {
  my ( $self, $pin, $args ) = @_;
  my $subcommand = 0;
  my @data;
  if (defined $args->{reset}) {
    $subcommand |= $ONE_WIRE_COMMANDS->{RESET_REQUEST_BIT};
  }
  if (defined $args->{skip}) {
    $subcommand |= $ONE_WIRE_COMMANDS->{SKIP_REQUEST_BIT};
  }
  if (defined $args->{select}) {
    $subcommand |= $ONE_WIRE_COMMANDS->{SELECT_REQUEST_BIT};
    push_onewire_device_to_byte_array($args->{select},\@data);
  }
  if (defined $args->{read}) {
    $subcommand |= $ONE_WIRE_COMMANDS->{READ_REQUEST_BIT};
    push @data,$args->{read} & 0xFF;
    push @data,($args->{read}>>8) & 0xFF;
    if ($self->{protocol_version} ne 'V_2_04') {
      my $id = (defined $args->{id}) ? $args->{id} : 0;
      push @data,$id &0xFF;
      push @data,($id>>8) & 0xFF;
    }
  }
  if (defined $args->{delay}) {
    $subcommand |= $ONE_WIRE_COMMANDS->{DELAY_REQUEST_BIT};
    push @data,$args->{delay} & 0xFF;
    push @data,($args->{delay}>>8) & 0xFF;
    push @data,($args->{delay}>>16) & 0xFF;
    push @data,($args->{delay}>>24) & 0xFF;
  }
  if (defined $args->{write}) {
    $subcommand |= $ONE_WIRE_COMMANDS->{WRITE_REQUEST_BIT};
    my $writeBytes=$args->{write};
    push @data,@$writeBytes;
  }
  return $self->packet_sysex_command( ONEWIRE_DATA, $subcommand, $pin, pack_as_7bit(@data));
};

sub handle_onewire_reply {
  my ( $self, $sysex_data ) = @_;
  my $command = shift @$sysex_data;
  my $pin     = shift @$sysex_data;

  if ( defined $command ) {
    COMMAND_HANDLER: {
      $command == $ONE_WIRE_COMMANDS->{READ_REPLY} and do {    #PIN,COMMAND,ADDRESS,DATA
        my @data = unpack_from_7bit(@$sysex_data);
        if ($self->{protocol_version} eq 'V_2_04') {
          my $device = shift_onewire_device_from_byte_array(\@data);
          return {
            pin     => $pin,
            command => 'READ_REPLY',
            device  => $device,
            data    => \@data
          };
        } else {
          my $id = shift @data;
          $id += (shift @data)<<8;
          return {
            pin     => $pin,
            command => 'READ_REPLY',
            id      => $id,
            data    => \@data
          };
        };
      };

      ($command == $ONE_WIRE_COMMANDS->{SEARCH_REPLY} or $command == $ONE_WIRE_COMMANDS->{SEARCH_ALARMS_REPLY}) and do {    #PIN,COMMAND,ADDRESS...
        my @devices;
        my @data = unpack_from_7bit(@$sysex_data);
        my $device = shift_onewire_device_from_byte_array(\@data);
        while ( defined $device ) {
          push @devices, $device;
          $device = shift_onewire_device_from_byte_array(\@data);
        }
        return {
          pin     => $pin,
          command => $command == $ONE_WIRE_COMMANDS->{SEARCH_REPLY} ? 'SEARCH_REPLY' : 'SEARCH_ALARMS_REPLY',
          devices => \@devices,
        };
      };
    }
  }
}

sub packet_create_task {
  my ($self,$id,$len) = @_;
  my $packet = $self->packet_sysex_command('SCHEDULER_DATA', $SCHEDULER_COMMANDS->{CREATE_FIRMATA_TASK}, $id, $len & 0x7F, $len>>7);
  return $packet;
}

sub packet_delete_task {
  my ($self,$id) = @_;
  return $self->packet_sysex_command('SCHEDULER_DATA', $SCHEDULER_COMMANDS->{DELETE_FIRMATA_TASK}, $id);
}

sub packet_add_to_task {
  my ($self,$id,@data) = @_;
  my $packet = $self->packet_sysex_command('SCHEDULER_DATA', $SCHEDULER_COMMANDS->{ADD_TO_FIRMATA_TASK}, $id, pack_as_7bit(@data));
  return $packet;
}

sub packet_delay_task {
  my ($self,$time_ms) = @_;
  my $packet = $self->packet_sysex_command('SCHEDULER_DATA', $SCHEDULER_COMMANDS->{DELAY_FIRMATA_TASK}, pack_as_7bit($time_ms & 0xFF, ($time_ms & 0xFF00)>>8, ($time_ms & 0xFF0000)>>16,($time_ms & 0xFF000000)>>24));
  return $packet;
}

sub packet_schedule_task {
  my ($self,$id,$time_ms) = @_;
  my $packet = $self->packet_sysex_command('SCHEDULER_DATA', $SCHEDULER_COMMANDS->{SCHEDULE_FIRMATA_TASK}, $id, pack_as_7bit($time_ms & 0xFF, ($time_ms & 0xFF00)>>8, ($time_ms & 0xFF0000)>>16,($time_ms & 0xFF000000)>>24));
  return $packet;
}

sub packet_query_all_tasks {
  my $self = shift;
  return $self->packet_sysex_command('SCHEDULER_DATA', $SCHEDULER_COMMANDS->{QUERY_ALL_FIRMATA_TASKS});
}

sub packet_query_task {
  my ($self,$id) = @_;
  return $self->packet_sysex_command('SCHEDULER_DATA', $SCHEDULER_COMMANDS->{QUERY_FIRMATA_TASK},$id);
}

sub packet_reset_scheduler {
  my $self = shift;
  return $self->packet_sysex_command('SCHEDULER_DATA', $SCHEDULER_COMMANDS->{RESET_FIRMATA_TASKS});
}

sub handle_scheduler_response {
  my ( $self, $sysex_data ) = @_;
  my $command = shift @$sysex_data;

  if ( defined $command ) {
    COMMAND_HANDLER: {
      $command == $SCHEDULER_COMMANDS->{QUERY_ALL_TASKS_REPLY} and do {
        return {
          command => 'QUERY_ALL_TASKS_REPLY',
          ids => $sysex_data,
        }
      };

      ($command == $SCHEDULER_COMMANDS->{QUERY_TASK_REPLY} or $command == $SCHEDULER_COMMANDS->{ERROR_TASK_REPLY}) and do {
        my $error = ($command == $SCHEDULER_COMMANDS->{ERROR_TASK_REPLY});
        if (scalar @$sysex_data == 1) {
          return {
            command => ($error ? 'ERROR_TASK_REPLY' : 'QUERY_TASK_REPLY'),
            id => shift @$sysex_data,
          }
        }
        if (scalar @$sysex_data >= 11) {
          my $id = shift @$sysex_data;
          my @data = unpack_from_7bit(@$sysex_data);
          return {
            command => ($error ? 'ERROR_TASK_REPLY' : 'QUERY_TASK_REPLY'),
            id => $id,
            time_ms => shift @data | (shift @data)<<8 | (shift @data)<<16 | (shift @data)<<24,
            len => shift @data  | (shift @data)<<8,
            position => shift @data  | (shift @data)<<8,
            messages => \@data,
          }
        }
      };
    }
  }
}

#	stepper_data 0
#	stepper_config 1
#	devicenum 2 (0 < devicenum < 6)
#	interface (DRIVER | TWO_WIRE | FOUR_WIRE) 3
#	stepsPerRev 4+5 (14bit)
#	directionPin 6
#	stepPin 7
#	motorPin3 8 (interface FOUR_WIRE only)
#	motorPin4 9 (interface FOUR_WIRE only)

sub packet_stepper_config {
  my ( $self, $stepperNum, $interface, $stepsPerRev, $directionPin, $stepPin, $motorPin3, $motorPin4 ) = @_;
  
  die "invalid stepper interface ".$interface unless defined ($STEPPER_INTERFACES->{$interface});
  my @configdata = ($stepperNum,$STEPPER_INTERFACES->{$interface});
  
  push_value_as_two_7bit($stepsPerRev, \@configdata);
  push @configdata, $directionPin;
  push @configdata, $stepPin;
  
  if ($interface eq 'FOUR_WIRE') {
    push @configdata, $motorPin3;
    push @configdata, $motorPin4;
  }
  my $packet = $self->packet_sysex_command('STEPPER_DATA',$STEPPER_COMMANDS->{STEPPER_CONFIG},@configdata);
  return $packet;
}

#	stepper_data 0
#	stepper_step 1
#	devicenum 2
#	stepDirection 3 0/>0
#	numSteps 4,5,6 (21bit)
#	stepSpeed 7,8 (14bit)
#	accel 9,10 (14bit, optional, aber nur zusammen mit decel)
#	decel 11,12 (14bit, optional, aber nur zusammen mit accel)

sub packet_stepper_step {
  my ( $self, $stepperNum, $direction, $numSteps, $stepSpeed, $accel, $decel ) = @_;
  my @stepdata = ($stepperNum, $direction);
  push @stepdata, $numSteps & 0x7f;
  push @stepdata, ($numSteps >> 7) & 0x7f;
  push @stepdata, ($numSteps >> 14) & 0x7f;
  push_value_as_two_7bit($stepSpeed, \@stepdata);
  if (defined $accel and defined $decel) {
    push_value_as_two_7bit($accel, \@stepdata);
    push_value_as_two_7bit($decel, \@stepdata);
  }
  my $packet = $self->packet_sysex_command('STEPPER_DATA', $STEPPER_COMMANDS->{STEPPER_STEP},@stepdata);
  return $packet;
}

sub handle_stepper_response {
  my ( $self, $sysex_data ) = @_;

  my $stepperNum = shift @$sysex_data;
  return {
    stepperNum => $stepperNum,
  };
}

sub handle_accelstepper_response {
  my ( $self, $sysex_data ) = @_;

  my $command = shift @$sysex_data;
  my $number = shift @$sysex_data;
  my $position = 0;

  if ( defined $command ) {
    if ( $command == 10 ) {
      my @data = unpack_from_7bit(@$sysex_data);
      $position = decode32BitSignedInteger(@$sysex_data);
      #printf "Stepper %d move complete; Position: %d\n", $number, $position;
    };

    if ( $command == 6 ) {
      my @data = unpack_from_7bit(@$sysex_data);
      $position = decode32BitSignedInteger(@$sysex_data);
      #printf "Stepper %d report position; Position: %d\n", $number, $position;
    };

    if ( $command == 36 ) {
      printf "MultiStepper %d move complete\n", $number;
    };
  };

  return {
    stepperNum => $number,
    position => $position,
  };
}

# AccelStepper

# $stepperNum {number} deviceNum Device number for the stepper (range 0-9)
# $speed {number} speed Desired speed or maxSpeed in steps per second

sub packet_accelstepper_speed {
  my ( $self, $stepperNum, $speed ) = @_;

  if ($stepperNum < 0 || $stepperNum > 9) {
    die "Invalid stepperNum: $stepperNum Expected stepperNum between 0-9\n";
  }

  my @stepdata = ($stepperNum);

  my $packet = $self->packet_sysex_command('ACCELSTEPPER_DATA', $ACCELSTEPPER_COMMANDS->{STEPPER_SPEED}, @stepdata, encodeCustomFloat($speed));

  return $packet;
}

# $stepperNum {number} deviceNum Device number for the stepper (range 0-9)
# $acceleration {number} acceleration Desired acceleration in steps per sec^2

sub packet_accelstepper_accel {
  my ( $self, $stepperNum, $acceleration ) = @_;

  if ($stepperNum < 0 || $stepperNum > 9) {
    die "Invalid stepperNum: $stepperNum Expected stepperNum between 0-9\n";
  }

  my @stepdata = ($stepperNum);

  my $packet = $self->packet_sysex_command('ACCELSTEPPER_DATA', $ACCELSTEPPER_COMMANDS->{STEPPER_ACCEL}, @stepdata, encodeCustomFloat($acceleration));

  return $packet;
}

# $stepperNum {number} deviceNum Device number for the stepper (range 0-9)
# $state {boolean} [enabled]

sub packet_accelstepper_enable {
  my ( $self, $stepperNum, $state ) = @_;

  if ($stepperNum < 0 || $stepperNum > 9) {
    die "Invalid stepperNum: $stepperNum Expected stepperNum between 0-9\n";
  }

  my @stepdata = ($stepperNum, $state);

  my $packet = $self->packet_sysex_command('ACCELSTEPPER_DATA', $ACCELSTEPPER_COMMANDS->{STEPPER_ENABLE}, @stepdata);

  return $packet;
}

# $stepperNum {number} deviceNum Device number for the stepper (range 0-9)
# $numSteps {number} steps Number of steps to make

sub packet_accelstepper_step {
  my ( $self, $stepperNum, $numSteps ) = @_;

  if ($stepperNum < 0 || $stepperNum > 9) {
    die "Invalid stepperNum: $stepperNum Expected stepperNum between 0-9\n";
  }

  my @stepdata = ($stepperNum);

  my $packet = $self->packet_sysex_command('ACCELSTEPPER_DATA', $ACCELSTEPPER_COMMANDS->{STEPPER_STEP}, @stepdata, encode32BitSignedInteger($numSteps));

  return $packet;
}

# $stepperNum {number} deviceNum Device number for the stepper (range 0-9)

sub packet_accelstepper_zero {
  my ( $self, $stepperNum ) = @_;

  if ($stepperNum < 0 || $stepperNum > 9) {
    die "Invalid stepperNum: $stepperNum Expected stepperNum between 0-9\n";
  }

  my @stepdata = ($stepperNum);

  my $packet = $self->packet_sysex_command('ACCELSTEPPER_DATA', $ACCELSTEPPER_COMMANDS->{STEPPER_ZERO}, @stepdata);

  return $packet;
}

# $stepperNum {number} deviceNum Device number for the stepper (range 0-9)
# $position {number} position Desired position

sub packet_accelstepper_to {
  my ( $self, $stepperNum, $position ) = @_;

  if ($stepperNum < 0 || $stepperNum > 9) {
    die "Invalid stepperNum: $stepperNum Expected stepperNum between 0-9\n";
  }

  my @stepdata = ($stepperNum);

  my $packet = $self->packet_sysex_command('ACCELSTEPPER_DATA', $ACCELSTEPPER_COMMANDS->{STEPPER_TO}, @stepdata, encode32BitSignedInteger($position));

  return $packet;
}

# $stepperNum {number} deviceNum Device number for the stepper (range 0-9)

sub packet_accelstepper_stop {
  my ( $self, $stepperNum ) = @_;

  if ($stepperNum < 0 || $stepperNum > 9) {
    die "Invalid stepperNum: $stepperNum Expected stepperNum between 0-9\n";
  }

  my @stepdata = ($stepperNum);

  my $packet = $self->packet_sysex_command('ACCELSTEPPER_DATA', $ACCELSTEPPER_COMMANDS->{STEPPER_STOP}, @stepdata);

  return $packet;
}

# $stepperNum {number} deviceNum Device number for the stepper (range 0-9)

sub packet_accelstepper_report {
  my ( $self, $stepperNum ) = @_;

  if ($stepperNum < 0 || $stepperNum > 9) {
    die "Invalid stepperNum: $stepperNum Expected stepperNum between 0-9\n";
  }

  my @stepdata = ($stepperNum);

  my $packet = $self->packet_sysex_command('ACCELSTEPPER_DATA', $ACCELSTEPPER_COMMANDS->{STEPPER_REPORT}, @stepdata);

  return $packet;
}

# $groupNum {number} groupNum Group number for the multiSteppers (range 0-4)
# @positions array {number} positions array of absolute stepper positions

sub packet_multistepper_to {
  my ( $self, $groupNum, @positions ) = @_;

  my @groupdata = ($groupNum);
  my @concat_pos;

  if ($groupNum < 0 || $groupNum > 4) {
    printf "Invalid groupNum: $groupNum Expected groupNum between 0-4\n";
  }

  if (@positions < 0 || @positions > 9) {
    die "Invalid positions: @positions Expected positions number between 0-9\n";
  }

  #  ...positions.reduce((a, b) => a.concat(...encode32BitSignedInteger(b)), []),
  foreach (@positions) {
    push( @concat_pos,  encode32BitSignedInteger($_))
  }

  my $packet = $self->packet_sysex_command('ACCELSTEPPER_DATA', $ACCELSTEPPER_COMMANDS->{STEPPER_MULTITO}, @groupdata, @concat_pos);

  return $packet;
}

# $groupNum {number} groupNum Group number for the multiSteppers (range 0-4)

sub packet_multistepper_stop {
  my ( $self, $groupNum ) = @_;

  my @groupdata = ($groupNum);

  if ($groupNum < 0 || $groupNum > 4) {
    die "Invalid groupNum: $groupNum Expected groupNum between 0-4\n";
  }

  my $packet = $self->packet_sysex_command('ACCELSTEPPER_DATA', $ACCELSTEPPER_COMMANDS->{STEPPER_MULTISTOP}, @groupdata);

  return $packet;
}

# $groupNum {number} groupNum: Group number for the multiSteppers (range 0-4)
# @devices array {number} devices: array of accelStepper device numbers in group

sub packet_multistepper_config {
  my ( $self, $groupNum, @devices ) = @_;

  my @groupdata = ($groupNum);

  if ($groupNum < 0 || $groupNum > 4) {
    die "Invalid groupNum: $groupNum Expected groupNum between 0-4\n";
  }

  if (@devices < 0 || @devices > 9) {
    die "Invalid devices: @devices Expected devices number between 0-9\n";
  }

  my $packet = $self->packet_sysex_command('ACCELSTEPPER_DATA', $ACCELSTEPPER_COMMANDS->{STEPPER_MULTICONFIG}, @groupdata, @devices);

  return $packet;
}

# $stepperNum: stepper id: 0, 1, 2.. 9
# $interface:
#   'DRIVER': use $pin1: step, $pin2: dir.
#   'TWO_WIRE': use $pin1, $pin2.
#   'THREE_WIRE': use $pin1, $pin2, $pin3.
#   'FOUR_WIRE': use $pin1, $pin2, $pin3, $pin4.
# $step: 'WHOLE', 'HALF', 'QUARTER' steps.
# $pin1, $pin2: mandatory.
# $pin3, $pin4: optional depending $interface.
# $enablePin: optional pin for driver with enable pin.
# $invertPins: optional array with pins to invert.

sub packet_accelstepper_config {
  my ( $self, $stepperNum, $interface, $step, $pin1, $pin2, $pin3, $pin4, $enablePin, @invertPins ) = @_;

  if ($stepperNum < 0 || $stepperNum > 9) {
    die "Invalid stepperNum: $stepperNum Expected stepperNum between 0-9\n";
  }

  die "invalid accelstepper interface".$interface unless defined ($ACCELSTEPPER_INTERFACES->{$interface});

  die "invalid accelstepper step".$step unless defined ($ACCELSTEPPER_STEP->{$step});

  my $iface = (($ACCELSTEPPER_INTERFACES->{$interface} & 0x07) << 4) | (($ACCELSTEPPER_STEP->{$step} & 0x07) << 1) ;

  if (defined $enablePin) {
    $iface = $iface | 0x01;
  }

  my @configdata = ($stepperNum, $iface);

  if (!defined $pin1) {
    die "pin1 not defined\n";
  }
  push @configdata, $pin1;

  if (!defined $pin2) {
    die "pin1 not defined\n";
  }
  push @configdata, $pin2;

  if (defined $pin3) {
    push @configdata, $pin3;
  }

  if (defined $pin4) {
    push @configdata, $pin4;
  }

  if (defined $enablePin) {
    push @configdata, $enablePin;
  }

  my $pinsToInvert = 0x00;

  if (@invertPins > 0) {

    my %invert = map { $_ => 1 } @invertPins;

    if(exists($invert{$pin1})) {
      $pinsToInvert |= 0x01;
    }

    if(exists($invert{$pin2})) {
      $pinsToInvert |= 0x02;
    }

    if((defined $pin3) && exists($invert{$pin3})) {
      $pinsToInvert |= 0x04;
    }

    if((defined $pin4) && exists($invert{$pin4})) {
      $pinsToInvert |= 0x08;
    }

    if((defined $enablePin) && exists($invert{$enablePin})) {
      $pinsToInvert |= 0x10;
    }
  }

  push @configdata, $pinsToInvert;

  my $packet = $self->packet_sysex_command('ACCELSTEPPER_DATA',$ACCELSTEPPER_COMMANDS->{STEPPER_CONFIG}, @configdata);

  return $packet;
}

###

sub packet_encoder_attach {
  my ( $self,$encoderNum, $pinA, $pinB ) = @_;
  my $packet = $self->packet_sysex_command('ENCODER_DATA', $ENCODER_COMMANDS->{ENCODER_ATTACH}, $encoderNum, $pinA, $pinB);
  return $packet;
}

sub packet_encoder_report_position {
  my ( $self,$encoderNum ) = @_;
  my $packet = $self->packet_sysex_command('ENCODER_DATA', $ENCODER_COMMANDS->{ENCODER_REPORT_POSITION}, $encoderNum);
  return $packet;
}

sub packet_encoder_report_positions {
  my ( $self ) = @_;
  my $packet = $self->packet_sysex_command('ENCODER_DATA', $ENCODER_COMMANDS->{ENCODER_REPORT_POSITIONS});
  return $packet;
}

sub packet_encoder_reset_position {
  my ( $self,$encoderNum ) = @_;
  my $packet = $self->packet_sysex_command('ENCODER_DATA', $ENCODER_COMMANDS->{ENCODER_RESET_POSITION}, $encoderNum);
  return $packet;
}

sub packet_encoder_report_auto {
  my ( $self,$arg ) = @_;
  my $packet = $self->packet_sysex_command('ENCODER_DATA', $ENCODER_COMMANDS->{ENCODER_REPORT_AUTO}, $arg);
  return $packet;
}

sub packet_encoder_detach {
  my ( $self,$encoderNum ) = @_;
  my $packet = $self->packet_sysex_command('ENCODER_DATA', $ENCODER_COMMANDS->{ENCODER_DETACH}, $encoderNum);
  return $packet;
}

sub handle_encoder_response {
  my ( $self, $sysex_data ) = @_;
  
  my @retval = ();
  
  while (@$sysex_data) {
    
    my $command = shift @$sysex_data;
    my $direction = ($command & 0x40) >> 6;
    my $encoderNum = $command & 0x3f;
    my $value = shift14bit($sysex_data) + (shift14bit($sysex_data) << 14);
    
    push @retval,{
      encoderNum => $encoderNum,
      value => $direction ? -1 * $value : $value,
    };
  };
  
  return \@retval;
}

#/* serial config
# * -------------------------------
# * 0  START_SYSEX      (0xF0)
# * 1  SERIAL_DATA      (0x60)  // command byte
# * 2  SERIAL_CONFIG    (0x10)  // OR with port (0x11 = SERIAL_CONFIG | HW_SERIAL1)
# * 3  baud             (bits 0 - 6)
# * 4  baud             (bits 7 - 13)
# * 5  baud             (bits 14 - 20) // need to send 3 bytes for baud even if value is < 14 bits
# * 6  rxPin            (0-127) [optional] // only set if platform requires RX pin number
# * 7  txPin            (0-127) [optional] // only set if platform requires TX pin number
# * 6|8 END_SYSEX       (0xF7)
# */

sub packet_serial_config {
  my ( $self, $port, $baud, $rxPin, $txPin ) = @_;
  if (defined($rxPin) && defined($txPin)) {
    return $self->packet_sysex_command( SERIAL_DATA,
      $SERIAL_COMMANDS->{SERIAL_CONFIG} | $port,
      $baud & 0x7f,
      ($baud >> 7) & 0x7f,
      ($baud >> 14) & 0x7f,
      $rxPin & 0x7f,
      $txPin & 0x7f
    );
  } else {  
    return $self->packet_sysex_command( SERIAL_DATA,
      $SERIAL_COMMANDS->{SERIAL_CONFIG} | $port,
      $baud & 0x7f,
      ($baud >> 7) & 0x7f,
      ($baud >> 14) & 0x7f
    );
  }
}

#/* serial listen
# * -------------------------------
# * 0  START_SYSEX      (0xF0)
# * 1  SERIAL_DATA      (0x60)  // command byte
# * 2  SERIAL_LISTEN    (0x70)  // OR with port to switch to (0x79 = switch to SW_SERIAL1)
# * 3  END_SYSEX        (0xF7)
# */

sub packet_serial_listen {
  my ( $self, $port ) = @_;
  return $self->packet_sysex_command( SERIAL_DATA,
    $SERIAL_COMMANDS->{SERIAL_LISTEN} | $port
  );
}

#/* serial write
# * -------------------------------
# * 0  START_SYSEX      (0xF0)
# * 1  SERIAL_DATA      (0x60)
# * 2  SERIAL_WRITE     (0x20) // OR with port (0x21 = SERIAL_WRITE | HW_SERIAL1)
# * 3  data 0           (LSB)
# * 4  data 0           (MSB)
# * 5  data 1           (LSB)
# * 6  data 1           (MSB)
# * ...                 // up to max buffer - 5
# * n  END_SYSEX        (0xF7)
# */

sub packet_serial_write {
  my ( $self, $port, @serialdata ) = @_;
  
  if (scalar @serialdata) {
    my @data;
    push_array_as_two_7bit(\@serialdata,\@data);
    return $self->packet_sysex_command( SERIAL_DATA,
      $SERIAL_COMMANDS->{SERIAL_WRITE} | $port,
      @data
    );
  } else {
    return $self->packet_sysex_command( SERIAL_DATA,
      $SERIAL_COMMANDS->{SERIAL_WRITE} | $port
    );
  }
}

#/* serial read
# * -------------------------------
# * 0  START_SYSEX        (0xF0)
# * 1  SERIAL_DATA        (0x60)
# * 2  SERIAL_READ        (0x30) // OR with port (0x31 = SERIAL_READ | HW_SERIAL1)
# * 3  SERIAL_READ_MODE   (0x00) // 0x00 => read continuously, 0x01 => stop reading
# * 4  maxBytesToRead     (lsb)  // 0x00 for all bytes available [optional]
# * 5  maxBytesToRead     (msb)  // 0x00 for all bytes available [optional]
# * 4|6 END_SYSEX         (0xF7)
# */

sub packet_serial_read {
  my ( $self, $port, $command, $maxBytes ) = @_;
  
  if ($maxBytes > 0) { 
    return $self->packet_sysex_command( SERIAL_DATA,
      $SERIAL_COMMANDS->{SERIAL_READ} | $port,
      $command,
      $maxBytes & 0x7f,
      ($maxBytes >> 7) & 0x7f
    );
  } else {
    return $self->packet_sysex_command( SERIAL_DATA,
      $SERIAL_COMMANDS->{SERIAL_READ} | $port,
      $command
    );
  }
}

#/* serial reply
# * -------------------------------
# * 0  START_SYSEX        (0xF0)
# * 1  SERIAL_DATA        (0x60)
# * 2  SERIAL_REPLY       (0x40) // OR with port (0x41 = SERIAL_REPLY | HW_SERIAL1)
# * 3  data 0             (LSB)
# * 4  data 0             (MSB)
# * 3  data 1             (LSB)
# * 4  data 1             (MSB)
# * ...                   // up to max buffer - 5
# * n  END_SYSEX          (0xF7)
# */

sub handle_serial_reply {
  my ( $self, $sysex_data ) = @_;
  
  my $command = shift @$sysex_data;
  my $port = $command & 0xF;
  my @data = double_7bit_to_array($sysex_data);
  return {
    port => $port,
    data => \@data,
  };
}

sub shift14bit {
  my $data = shift;
  my $lsb  = shift @$data;
  my $msb  = shift @$data;
  return
      defined $lsb
    ? defined $msb
      ? ( $msb << 7 ) + ( $lsb & 0x7f )
      : $lsb
    : undef;
}

sub double_7bit_to_string {
  my ( $data, $numbytes ) = @_;
  my $ret;
  if ( defined $numbytes ) {
    for ( my $i = 0 ; $i < $numbytes ; $i++ ) {
      my $value = shift14bit($data);
      $ret .= chr($value);
    }
  }
  else {
    while (@$data) {
      my $value = shift14bit($data);
      $ret .= chr($value);
    }
  }
  return $ret;
}

sub double_7bit_to_array {
  my ( $data, $numbytes ) = @_;
  my @ret;
  if ( defined $numbytes ) {
    for ( my $i = 0 ; $i < $numbytes ; $i++ ) {
      push @ret, shift14bit($data);
    }
  }
  else {
    while (@$data) {
      my $value = shift14bit($data);
      push @ret, $value;
    }
  }
  return @ret;
}

sub shift_onewire_device_from_byte_array {
  my $buffer = shift;
  my $family = shift @$buffer;
  if ( defined $family ) {
    my @address;
    for (my $i=0;$i<6;$i++) { push @address,shift @$buffer; }
    my $crc = shift @$buffer;
    return {
      family   => $family,
      identity => \@address,
      crc      => $crc
    };
  }
  else {
    return undef;
  }
}

sub push_value_as_two_7bit {
  my ( $value, $buffer ) = @_;
  push @$buffer, $value & 0x7f;    #LSB
  push @$buffer, ( $value >> 7 ) & 0x7f;    #MSB
}

sub push_onewire_device_to_byte_array {
  my ( $device, $buffer ) = @_;
  push @$buffer, $device->{family};
  for ( my $i = 0 ; $i < 6 ; $i++ ) { push @$buffer, $device->{identity}[$i]; }
  push @$buffer, $device->{crc};
}

sub push_array_as_two_7bit {
  my ( $data, $buffer ) = @_;
  my $byte = shift @$data;
  while ( defined $byte ) {
    push_value_as_two_7bit( $byte, $buffer );
    $byte = shift @$data;
  }
}

sub pack_as_7bit {
  printf "pack_as_7bit\n";
  my @data = @_;
  my @outdata;
  my $numBytes    = @data;
  my $messageSize = ( $numBytes << 3 ) / 7;
  for ( my $i = 0 ; $i < $messageSize ; $i++ ) {
    my $j     = $i * 7;
    my $pos   = $j >> 3;
    my $shift = $j & 7;
    my $out   = $data[$pos] >> $shift & 0x7F;
    printf "%b, %b, %d\n",$data[$pos],$out,$shift if ($out >> 7 > 0);
    $out |= ( $data[ $pos + 1 ] << ( 8 - $shift ) ) & 0x7F if ( $shift > 1 && $pos < $numBytes-1 );
    push( @outdata, $out );
    printf "push outdata @outdata out $out\n";
  }
  return @outdata;
}

sub unpack_from_7bit {
  my @data = @_;
  my @outdata;
  my $numBytes = @data;
  my $outBytes = ( $numBytes * 7 ) >> 3;
  for ( my $i = 0 ; $i < $outBytes ; $i++ ) {
    my $j     = $i << 3;
    my $pos   = $j / 7;
    my $shift = $j % 7;
    push( @outdata,
      ( $data[$pos] >> $shift ) |
        ( ( $data[ $pos + 1 ] << ( 7 - $shift ) ) & 0xFF ) );
  }
  return @outdata;
}

sub encode32BitSignedInteger {
  my ( $data ) = @_;
  my @outdata;

  my $abs_data = abs($data);

  push( @outdata, ($abs_data & 0x7F));
  push( @outdata, (($abs_data >> 7) & 0x7F));
  push( @outdata, (($abs_data >> 14) & 0x7F));
  push( @outdata, (($abs_data >> 21) & 0x7F));
  push( @outdata, (($abs_data >> 28) & 0x07));

  if ( $data < 0 ) {
    $outdata[-1] |= 0x08;
  };

  return @outdata;

};

sub decode32BitSignedInteger {
  my @data = @_;

  my $result = ($data[0] & 0x7F) |
    (($data[1] & 0x7F) << 7) |
    (($data[2] & 0x7F) << 14) |
    (($data[3] & 0x7F) << 21) |
    (($data[4] & 0x07) << 28);


  if ($data[4] >> 3) {
    $result *= -1;
  }

  return $result;
};

sub encodeCustomFloat {
  my ( $data ) = @_;
  my $sign = 0;
  my $MAX_SIGNIFICAND = (2**23);
  my @encoded;

  if ( $data < 0 ) {
    $sign = 1;
  };

  if ( $data != 0 ) {

    my $abs_data = abs($data);

    my $base10 = floor(log($abs_data)/log(10));

    my $exponent = 0 + $base10;

    $abs_data /= (10**$base10);

    while ( $abs_data =~ /^\d*\.\d*$/ && $abs_data < $MAX_SIGNIFICAND) {
      $exponent -= 1;
      $abs_data *= 10;
    };

    while ( $abs_data > $MAX_SIGNIFICAND) {
      $exponent += 1;
      $abs_data /= 10;
    };

    my $int_data = int($abs_data);

    $exponent += 11;

    push( @encoded, ($int_data & 0x7F));
    push( @encoded, (($int_data >> 7) & 0x7F));
    push( @encoded, (($int_data >> 14) & 0x7F));
    push ( @encoded, ( ($int_data >> 21) & 0x03 | ($exponent & 0x0F) << 2 | ($sign & 0x01) << 6 ) );

  };

  if ($data == 0 ) {
    push ( @encoded, (0,0,0,0));
  };

  return @encoded;

};

=head2 get_max_compatible_protocol_version

Search list of implemented protocols for identical or next lower version.

=cut

sub get_max_supported_protocol_version {
  my ( $self, $deviceProtcolVersion ) = @_;
  return "V_2_01" unless (defined($deviceProtcolVersion));                       # min. supported protocol version if undefined
  return $deviceProtcolVersion if (defined($COMMANDS->{$deviceProtcolVersion})); # requested version if known
  
  my $maxSupportedProtocolVersion = undef;
  foreach my $protocolVersion (sort keys %{$COMMANDS}) {
    if ($protocolVersion lt $deviceProtcolVersion) {
      $maxSupportedProtocolVersion = $protocolVersion;                           # nearest lower version if not known
    }
  }
  
  return $maxSupportedProtocolVersion;
}

1;
