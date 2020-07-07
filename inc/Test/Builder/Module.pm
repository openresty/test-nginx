#line 1
package Test::Builder::Module;

use strict;

use Test::Builder;

require Exporter;
our @ISA = qw(Exporter);

our $VERSION = '1.302171';


#line 73

sub import {
    my($class) = shift;

    Test2::API::test2_load() unless Test2::API::test2_in_preload();

    # Don't run all this when loading ourself.
    return 1 if $class eq 'Test::Builder::Module';

    my $test = $class->builder;

    my $caller = caller;

    $test->exported_to($caller);

    $class->import_extra( \@_ );
    my(@imports) = $class->_strip_imports( \@_ );

    $test->plan(@_);

    local $Exporter::ExportLevel = $Exporter::ExportLevel + 1;
    $class->Exporter::import(@imports);
}

sub _strip_imports {
    my $class = shift;
    my $list  = shift;

    my @imports = ();
    my @other   = ();
    my $idx     = 0;
    while( $idx <= $#{$list} ) {
        my $item = $list->[$idx];

        if( defined $item and $item eq 'import' ) {
            push @imports, @{ $list->[ $idx + 1 ] };
            $idx++;
        }
        else {
            push @other, $item;
        }

        $idx++;
    }

    @$list = @other;

    return @imports;
}

#line 139

sub import_extra { }

#line 169

sub builder {
    return Test::Builder->new;
}

#line 180

1;
