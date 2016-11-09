package Module::Reader;
BEGIN { require 5.006 }
use strict;
use warnings;

our $VERSION = '0.002003';
$VERSION = eval $VERSION;

use Exporter (); *import = \&Exporter::import;
our @EXPORT_OK = qw(module_content module_handle);
our %EXPORT_TAGS = (all => [@EXPORT_OK]);

use File::Spec;
use Scalar::Util qw(blessed reftype refaddr openhandle);
use Carp;
use Config ();
use Errno qw(EACCES);
use constant _PMC_ENABLED => !(
  exists &Config::non_bincompat_options ? grep { $_ eq 'PERL_DISABLE_PMC' } Config::non_bincompat_options()
  : $Config::Config{ccflags} =~ /(?:^|\s)-DPERL_DISABLE_PMC\b/
);
use constant _VMS => $^O eq 'VMS' && !!require VMS::Filespec;
use constant _WIN32 => $^O eq 'MSWin32';
use constant _FAKE_FILE_FORMAT => do {
  (my $uvx = $Config::Config{uvxformat}||'') =~ tr/"//d;
  $uvx ||= 'lx';
  "/loader/0x%$uvx/%s"
};

sub _mod_to_file {
  my $module = shift;
  (my $file = "$module.pm") =~ s{::}{/}g;
  $file;
}

sub module_content {
  my $opts = ref $_[-1] eq 'HASH' && pop @_ || {};
  my $module = shift;
  $opts->{inc} = [@_]
    if @_;
  __PACKAGE__->new($opts)->module($module)->content;
}

sub module_handle {
  my $opts = ref $_[-1] eq 'HASH' && pop @_ || {};
  my $module = shift;
  $opts->{inc} = [@_]
    if @_;
  __PACKAGE__->new($opts)->module($module)->handle;
}

sub new {
  my $class = shift;
  my %options;
  if (@_ == 1 && ref $_[-1]) {
    %options = %{(pop)};
  }
  elsif (@_ % 2 == 0) {
    %options = @_;
  }
  else {
    croak "Expected hash ref, or key value pairs.  Got ".@_." arguments.";
  }

  $options{inc} ||= \@INC;
  $options{found} = \%INC
    if exists $options{found} && $options{found} eq 1;
  $options{pmc} = _PMC_ENABLED
    if !exists $options{pmc};
  bless \%options, $class;
}

sub module {
  my ($self, $module) = @_;
  $self->file(_mod_to_file($module));
}

sub modules {
  my ($self, $module) = @_;
  $self->files(_mod_to_file($module));
}

sub file {
  my ($self, $file) = @_;
  $self->_find($file);
}

sub files {
  my ($self, $file) = @_;
  $self->_find($file, 1);
}

sub _searchable {
  my $file = shift;
    File::Spec->file_name_is_absolute($file) ? 0
  : _WIN32 && $file =~ m{^\.\.?[/\\]}        ? 0
  : $file =~ m{^\.\.?/}                      ? 0
                                             : 1
}

sub _find {
  my ($self, $file, $all) = @_;

  if (!_searchable($file)) {
    my $open = _open_file($file);
    return $open
      if $open;
    croak "Can't locate $file";
  }

  my @found;
  eval {
    if (my $found = $self->{found}) {
      if (defined( my $full = $found->{$file} )) {
        my $open = length ref $full ? $self->_open_ref($full, $file)
                                    : $self->_open_file($full, $file);
        push @found, $open
          if $open;
      }
    }
  };
  if (!$all) {
    return $found[0]
      if @found;
    die $@
      if $@;
  }
  my $search = $self->{inc};
  for my $inc (@$search) {
    my $open;
    eval {
      if (!length ref $inc) {
        my $full = _VMS ? VMS::Filespec::unixpath($inc) : $inc;
        $full =~ s{/?$}{/};
        $full .= $file;
        $open = $self->_open_file($full, $file, $inc);
      }
      else {
        $open = $self->_open_ref($inc, $file);
      }
      push @found, $open
        if $open;
    };
    if (!$all) {
      return $found[0]
        if @found;
      die $@
        if $@;
    }
  }
  croak "Can't locate $file"
    if !$all;
  return @found;
}

sub _open_file {
  my ($self, $full, $file, $inc) = @_;
  for my $try (
    ($self->{pmc} && $file =~ /\.pm\z/ ? $full.'c' : ()),
    $full,
  ) {
    my $pmc = $full eq $try;
    next
      if -e $try ? (-d _ || -b _) : $! != EACCES;
    my $fh;
    open $fh, '<:', $try
      and return Module::Reader::File->new(
        filename        => $file,
        raw_filehandle  => $fh,
        found_file      => $full,
        disk_file       => $try,
        is_pmc          => $pmc,
        (defined $inc ? (inc_entry => $inc) : ()),
      );
    croak "Can't locate $file:   $full: $!"
      if $pmc;
  }
  return;
}

sub _open_ref {
  my ($self, $inc, $file) = @_;

  my @cb = defined blessed $inc ? $inc->INC($file)
         : ref $inc eq 'ARRAY'  ? $inc->[0]->($inc, $file)
                                : $inc->($inc, $file);

  return
    unless length ref $cb[0];

  my $fake_file = sprintf _FAKE_FILE_FORMAT, refaddr($inc), $file;

  my $fh;
  my $cb;
  my $cb_options;

  if (reftype $cb[0] eq 'GLOB' && openhandle $cb[0]) {
    $fh = shift @cb;
  }

  if ((reftype $cb[0]||'') eq 'CODE') {
    $cb = $cb[0];
    $cb_options = @cb > 1 ? [ $cb[1] ] : undef;
  }
  elsif (!$fh) {
    return;
  }
  return Module::Reader::File->new(
    filename => $file,
    found_file => $fake_file,
    inc_entry => $inc,
    (defined $fh ? (raw_filehandle => $fh) : ()),
    (defined $cb ? (read_callback => $cb) : ()),
    (defined $cb_options ? (read_callback_options => $cb_options) : ()),
  );
}

{
  package Module::Reader::File;
  use constant _OPEN_STRING => "$]" >= 5.008 || (require IO::String, 0);

  sub new {
    my ($class, %opts) = @_;
    my $filename = $opts{filename};
    if (!exists $opts{module} && $opts{filename}
      && $opts{filename} =~ m{\A(\w+(?:/\w+)?)\.pm\z}) {
      my $module = $1;
      $module =~ s{/}{::}g;
      $opts{module} = $module;
    }
    bless \%opts, $class;
  }

  sub filename              { $_[0]->{filename} }
  sub module                { $_[0]->{module} }
  sub raw_filehandle        { $_[0]->{raw_filehandle} }
  sub found_file            { $_[0]->{found_file} }
  sub disk_file             { $_[0]->{disk_file} }
  sub is_pmc                { $_[0]->{is_pmc} }
  sub inc_entry             { $_[0]->{inc_entry} }
  sub read_callback         { $_[0]->{read_callback} }
  sub read_callback_options { $_[0]->{read_callback_options} }

  sub content {
    my $self = shift;
    my $fh = $self->raw_filehandle;
    my $cb = $self->read_callback;
    if ($fh && !$cb) {
      local $/;
      return scalar <$fh>;
    }
    my @params = @{$self->read_callback_options||[]};
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

  sub handle {
    my $self = shift;
    my $fh = $self->raw_filehandle;
    return $fh
      if $fh && !$self->read_callback;
    my $content = $self->content;
    if (_OPEN_STRING) {
      open my $fh, '<', \$content;
      return $fh;
    }
    else {
      return IO::String->new($content);
    }
  }
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
