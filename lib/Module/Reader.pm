package Module::Reader;
BEGIN { require 5.006 }
use strict;
use warnings;

our $VERSION = '0.002003';
$VERSION = eval $VERSION;

use base 'Exporter';
our @EXPORT_OK = qw(
  module_content
  module_handle
  module_filename
  inc_content
  inc_handle
  inc_filename
);
our %EXPORT_TAGS = (all => [@EXPORT_OK]);

use File::Spec;
use Scalar::Util qw(blessed reftype refaddr openhandle);
use Carp;
use Config ();
use Errno qw(EACCES);
use constant _OPEN_STRING => "$]" >= 5.008;
use constant _PMC_ENABLED => !(
  exists &Config::non_bincompat_options ? grep { $_ eq 'PERL_DISABLE_PMC' } Config::non_bincompat_options()
  : $Config::Config{ccflags} =~ /(?:^|\s)-DPERL_DISABLE_PMC\b/
);
use constant _VMS => $^O eq 'VMS';
use constant _FAKE_FILE_FORMAT => do {
  (my $uvx = $Config::Config{uvxformat}||'') =~ tr/"//d;
  $uvx ||= 'lx';
  "/loader/0x%$uvx/%s"
};
BEGIN {
  require IO::String
    if !_OPEN_STRING;
  require VMS::Filespec
    if _VMS;
}

sub _mod_to_file {
  my $module = shift;
  (my $file = "$module.pm") =~ s{::}{/}g;
  $file;
}

sub _options {
  my @inc = @_;
  my $opts = ref $_[-1] eq 'HASH' && pop @inc || {};
  if (@inc) {
    carp "Providing directory to search as a list is deprecated.  The 'inc' option should be used instead.";
    $opts->{inc} = \@inc
  }
  return $opts;
}

sub module_content {
  inc_content(_mod_to_file($_[0]), @_[1..$#_]);
}

sub inc_content {
  my ($fh, $cb, $file) = _get_file($_[0], _options(@_[1..$#_]));
  return _read($fh, $cb);
}

sub module_handle {
  inc_handle(_mod_to_file($_[0]), @_[1..$#_]);
}

sub inc_handle {
  my ($fh, $cb, $file) = _get_file($_[0], _options(@_[1..$#_]));
  return $fh
    if $fh && !$cb;
  my $content = _read($fh, $cb);
  if (_OPEN_STRING) {
    open my $fh, '<', \$content;
    return $fh;
  }
  else {
    return IO::String->new($content);
  }
}

sub module_filename {
  inc_filename(_mod_to_file($_[0]), @_[1..$#_]);
}

sub inc_filename {
  my ($fh, $cb, $file) = _get_file($_[0], _options(@_[1..$#_]));
  return $file;
}

sub _get_file {
  my ($file, $opts) = @_;
  my @inc = @{$opts->{inc}||\@INC};
  if (my $found = $opts->{found}) {
    if (defined( my $full = $found->{$file} )) {
      if (length ref $full) {
        @inc = $full;
      }
      elsif (-e $full && !-d _ && !-b _) {
        open my $fh, '<:', $full
          or croak "Can't locate $file:   $full: $!";
        return ($fh, undef, $full);
      }
    }
  }

  for my $inc (@inc) {
    if (!length ref $inc) {
      my $full = _VMS ? VMS::Filespec::unixpath($inc) : $inc;
      $full =~ s{/?$}{/};
      $full .= $file;
      for my $try ((_PMC_ENABLED && $file =~ /\.pm$/ ? $full.'c' : ()), $full) {
        next
          if -e $try ? (-d _ || -b _) : $! != EACCES;
        my $fh;
        open $fh, '<:', $try
          and return ($fh, undef, $try);
        croak "Can't locate $file:   $full: $!"
          if $try eq $full;
      }
      next;
    }

    my @cb = defined blessed $inc ? $inc->INC($file)
           : ref $inc eq 'ARRAY'  ? $inc->[0]->($inc, $file)
                                  : $inc->($inc, $file);

    next
      unless length ref $cb[0];

    my $fake_file = sprintf _FAKE_FILE_FORMAT, refaddr($inc), $file;

    my $fh;
    if (reftype $cb[0] eq 'GLOB' && openhandle $cb[0]) {
      $fh = shift @cb;
    }

    if ((reftype $cb[0]||'') eq 'CODE') {
      splice @cb, 2
        if @cb > 2;
      return ($fh, \@cb, $fake_file);
    }
    elsif ($fh) {
      return ($fh, undef, $fake_file);
    }
  }
  croak "Can't locate $file";
}

sub _read {
  my ($fh, $cb) = @_;
  if ($fh && !$cb) {
    local $/;
    return scalar <$fh>;
  }
  ($cb, my @params) = @$cb;
  my $content = '';
  while (1) {
    local $_ = $fh ? <$fh> : '';
    $_ = ''
      if !defined;
    last if !$cb->(0, @params);
    $content .= $_;
  }
  return $content;
}

1;

__END__

=head1 NAME

Module::Reader - Read the source of a module like perl does

=head1 SYNOPSIS

  use Module::Reader qw(:all);

  my $io = module_handle('My::Module');
  my $content = module_content('My::Module');
  my $filename = module_filename('My::Module');

  my $io = inc_handle('My/Module.pm');
  my $content = inc_content('My/Module.pm');
  my $filename = inc_filename('My/Module.pm');

  my $io = module_handle('My::Module', { inc => \@search_dirs } );

  my $io = module_handle('My::Module', { inc => \@search_dirs, found => \%INC } );

=head1 DESCRIPTION

Reads the content of perl modules the same way perl does.  This includes reading
modules available only by L<@INC hooks|perlfunc/require>, or filtered through
them.  Modules can be accessed as content, a file handle, or a filename.

=head1 EXPORTS

=head2 module_handle ( $module_name, \%options )

Returns an IO handle to the given module.

=head3 Options

=over 4

=item inc

A reference to an array like L<@INC|perlvar/@INC> with directories or hooks as
described in the documentation for L<require|perlfunc/require>.  If not
specified, C<@INC> will be used.

=item found

A reference to a hash like L<%INC|perlvar/%INC> with module file names (in the
style 'F<My/Module.pm>') as keys and full file paths as values.  Modules listed
in this will be used in preference to searching through directories.

=back

=head2 module_content ( $module_name, \%options )

Returns the content of the given module.  Accepts the same options as
L</module_handle>.

=head2 module_filename ( $module_name, \%options )

Returns the filename of the given module.  Accepts the same options as
L</module_handle>.  Filenames will be relative if the paths in C<@INC> are
relative.

For files provided by an hook, the filename will look like
C</loader/0x012345789abcdef/My/Module.pm>.  This should match the filename perl
will use internally for things like C<__FILE__> or L<caller()|perlfunc/caller>.
The hexadecimal value is the refaddr of the hook.

=head2 inc_handle ( $filename, \%options )

Works the same as L</module_handle>, but accepting a file path fragment rather
than a module name (e.g. C<My/Module.pm>).

=head2 inc_content ( $filename, \%options )

Works the same as L</module_content>, but accepting a file path fragment rather
than a module name.

=head2 inc_filename ( $filename, \%options )

Works the same as L</module_filename>, but accepting a file path fragment rather
than a module name.

=head1 AUTHOR

haarg - Graham Knop (cpan:HAARG) <haarg@haarg.org>

=head2 CONTRIBUTORS

None yet.

=head1 COPYRIGHT

Copyright (c) 2013 the Module::Reader L</AUTHOR> and L</CONTRIBUTORS>
as listed above.

=head1 LICENSE

This library is free software and may be distributed under the same terms
as perl itself.

=cut
