#!/usr/bin/perl -w

use File::Spec::Functions qw ( :ALL );
use File::stat;
use strict;
use warnings;

my $cfgdir = "config";
my $config_h = shift || "config.h";
my @input_files;

# Read in a whole file
#
sub read_file {
  my $file = shift;

  open my $fh, "<$file" or die "Could not open file $file: $!\n";
  local $/;
  my $data = <$fh>;
  close $fh;
  return $data;
}

# Write out a whole file
#
sub write_file {
  my $file = shift;
  my $data = shift;

  open my $fh, ">$file" or die "Could not write $file: $!\n";
  print $fh $data;
  close $fh;
}

# Delete a file
#
sub delete_file {
  my $file = shift;

  unlink $file or die "Could not delete $file: $!\n";
}

# Get a file modification time
#
sub file_mtime {
  my $file = shift;

  my $stat = stat ( $file ) or die "Could not stat $file: $!\n";
  return $stat->mtime;
}

# Read all the .h files in a directory
#
sub read_dir {
  my $dir = shift;

  opendir my $dh, $dir or die "Could not open directory $dir: $!\n";
  my @entries = grep { /\.h$/ } readdir $dh;
  closedir $dh;
  return @entries;
}

# Get the current configuration by reading the configuration file
# fragments
#
sub current_config {
  my $dir = shift;

  my $cfg = {};
  foreach my $file ( read_dir ( $dir ) ) {
    $cfg->{$file} = read_file ( catfile ( $dir, $file ) );
  }
  return $cfg;
}

# Calculate guard name for a header file
#
sub guard {
  my $name = shift;

  $name =~ s/\W/_/g;
  return "CONFIG_".( uc $name );
}

# Calculate preamble for a header file
#
sub preamble {
  my $name = shift;
  my $master = shift;

  my $guard = guard ( $name );
  my $preamble = <<"EOF";
/*
 * This file is automatically generated from $master.  Do not edit this
 * file; edit $master instead.
 *
 */

#ifndef $guard
#define $guard
EOF
  return $preamble;
}

# Calculate postamble for a header file
#
sub postamble {
  my $name = shift;

  my $guard = guard ( $name );
  return "\n#endif /* $guard */\n";
} 

# Parse one config.h file into an existing configuration
#
sub parse_config {
  my $file = shift;
  my $cfg = shift;
  my $cursor = "";

  push ( @input_files, $file );

  open my $fh, "<$file" or die "Could not open $file: $!\n";
  while ( <$fh> ) {
    if ( ( my $newcursor, my $suffix ) = /\@BEGIN\s+(\w+\.h)(.*)$/ ) {
      die "Missing \"\@END $cursor\" before \"\@BEGIN $1\""
	  ." at $file line $.\n" if $cursor;
      $cursor = $newcursor;
      $cfg->{$cursor} = preamble ( $cursor, $file )
	  unless exists $cfg->{$cursor};
      $cfg->{$cursor} .= "\n/*".$suffix."\n";
    } elsif ( ( my $prefix, my $oldcursor ) = /^(.*)\@END\s+(\w+\.h)/ ) {
      die "Missing \"\@BEGIN $oldcursor\" before \"\@END $oldcursor\""
	  ." at $file line $.\n" unless $cursor eq $oldcursor;
      $cfg->{$cursor} .= $prefix."*/\n";
      $cursor = "";
    } elsif ( ( my $newfile ) = /\@TRYSOURCE\s+([\w\-]+\.h)/ ) {
      die "Missing \"\@END $cursor\" before \"\@TRYSOURCE $newfile\""
	  ." at $file line $.\n" if $cursor;
      parse_config ( $newfile, $cfg ) if -e $newfile;
    } else {
      $cfg->{$cursor} .= $_ if $cursor;
    }
  }
  close $fh;
  die "Missing \"\@END $cursor\" in $file\n" if $cursor;
}

# Get the new configuration by splitting config.h file using the
# @BEGIN/@END tags
#
sub new_config {
  my $file = shift;
  my $cfg = {};

  parse_config ( $file, $cfg );

  foreach my $cursor ( keys %$cfg ) {
    $cfg->{$cursor} .= postamble ( $cursor );
  }

  return $cfg;
}  

#############################################################################
#
# Main program

# Read in current config file fragments
#
my $current = current_config ( $cfgdir );

# Read in config.h and split it into fragments
#
my $new = new_config ( $config_h );

# Delete any no-longer-wanted config file fragments
#
foreach my $file ( keys %$current ) {
  unlink catfile ( $cfgdir, $file ) unless exists $new->{$file};
}

# Write out any modified fragments, and find the oldest timestamp of
# any unmodified fragments.
#
my $oldest = time ();
foreach my $file ( keys %$new ) {
  if ( $current->{$file} && $new->{$file} eq $current->{$file} ) {
    # Unmodified
    my $time = file_mtime ( catfile ( $cfgdir, $file ) );
    $oldest = $time if $time < $oldest;
  } else {
    write_file ( catfile ( $cfgdir, $file ), $new->{$file} );
  }
}

# If we now have fragments that are older than config.h, set the
# timestamp on each input file to match the oldest fragment, to
# prevent make from always attempting to rebuild the fragments.
#
foreach my $file ( @input_files ) {
  if ( $oldest < file_mtime ( $file ) ) {
    utime time(), $oldest, $file or die "Could not touch $file: $!\n";
  }
}