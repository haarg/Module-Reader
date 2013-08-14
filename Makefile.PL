{ require 5.006 }
use strict;
use ExtUtils::MakeMaker 6.30;

my %WriteMakefileArgs = (
    NAME    => 'Module::Reader',
    AUTHOR  => 'Graham Knop <haarg@haarg.org>',
    LICENSE => 'perl',
    ABSTRACT_FROM => 'lib/Module/Reader.pm',
    VERSION_FROM => 'lib/Module/Reader.pm',

    PREREQ_PM => {
        ($] < 5.008 ? ('IO::String' => 0) : ()),
        'Scalar::Util'  => 0,
    },
    BUILD_REQUIRES => {
        'Test::More' => 0.88,
    },
    CONFIGURE_REQUIRES => {
        'ExtUtils::MakeMaker' => 6.30,
    },
    META_MERGE => {
        resources => {
            repository => 'git://github.com/haarg/Module-Reader.git',
            homepage => 'http://github.com/haarg/Module-Reader',
        },
        requires => {
            perl => 5.006,
        },
    }
);

unless ( eval { ExtUtils::MakeMaker->VERSION(6.56) } ) {
    my $br = delete $WriteMakefileArgs{BUILD_REQUIRES};
    my $pp = $WriteMakefileArgs{PREREQ_PM};
    for my $mod ( keys %$br ) {
        if ( exists $pp->{$mod} ) {
            $pp->{$mod} = $br->{$mod} if $br->{$mod} > $pp->{$mod};
        }
        else {
            $pp->{$mod} = $br->{$mod};
        }
    }
}

delete $WriteMakefileArgs{CONFIGURE_REQUIRES}
    unless eval { ExtUtils::MakeMaker->VERSION(6.52) };

WriteMakefile(%WriteMakefileArgs);
