use strict;
use ExtUtils::MakeMaker;
require 5.006;

WriteMakefile(
    NAME         => 'Module::Reader',
    VERSION_FROM => 'lib/Module/Reader.pm',

    PREREQ_PM => {
        ($] < 5.008 ? ('IO::String' => 0) : ()),
        'Scalar::Util'  => 0,
        'Test::More'    => 0.88,
    },
);

