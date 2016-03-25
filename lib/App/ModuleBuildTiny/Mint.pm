package App::ModuleBuildTiny::Mint;

use 5.010;

use strict;
use warnings FATAL => 'all';
our $VERSION = '0.018';

use Exporter 5.57 'import';
our @EXPORT = qw/mint_modulebuildtiny/;

use Carp qw/croak/;
use Data::Section::Simple 'get_data_section';
use Getopt::Long 2.36 'GetOptionsFromArray';
use Encode 'decode';
use ExtUtils::Manifest 'maniskip';
use File::Basename qw/dirname/;
use File::Path 'mkpath';
use File::Slurper 'write_text';
use File::Spec::Functions qw/catfile/;
use Module::Runtime 'require_module';
use Text::Template;

sub prompt {
	my($mess, $def) = @_;

	my $dispdef = defined $def ? " [$def]" : "";

	local $|=1;
	local $\;
	print "$mess$dispdef ";

	my $ans = <STDIN> // '';
	chomp $ans;
	return $ans ne '' ? decode('utf-8', $ans) : $def // '';
}

sub get_license {
	my ($license_name, $author) = @_;
	my $module = "Software::License::$license_name";
	require_module($module);
	return $module->new({ holder => $author });
}

sub fill_in {
	my ($template, $hash) = @_;
	return Text::Template->new(TYPE => 'STRING', SOURCE => $template)->fill_in(HASH => $hash);
}

sub write_module {
	my %opts = @_;
	my $template = get_data_section('Module.pm');
	my $filename = catfile('lib', split /::/, $opts{module_name}) . '.pm';
	my $content = fill_in($template, { %opts, end => '__END__' });
	mkpath(dirname($filename));
	write_text($filename, $content);
}

sub write_changes {
	my %opts = @_;
	my $template = get_data_section('Changes');
	my $content = fill_in($template, \%opts);
	write_text('Changes', $content);
}

sub write_maniskip {
	my $distname = shift;
	write_text('MANIFEST.SKIP', "#!include_default\n$distname-.*\n");
	maniskip(); # This expands the #!include_default as a side-effect
	unlink 'MANIFEST.SKIP.bak' if -f 'MANIFEST.SKIP.bak';
}

sub write_license {
	my $license = shift;
	write_text('LICENSE', $license->fulltext);
}

sub write_readme {
	my %opts = @_;
	my $template = get_data_section('README');
	write_text('README', fill_in($template, \%opts));
}

sub mint_modulebuildtiny {
	my (@arguments) = @_;
	my $distname = decode('utf-8', shift @arguments || prompt('What should be the name of this distribution'));
	croak "Directory $distname already exists" if -e $distname;

	my %args = (
		version => '0.001',
		dirname => $distname,
	);
	GetOptionsFromArray(\@arguments, \%args, qw/author=s version=s abstract=s license=s dirname=s/);
	$args{author} //= prompt('What is the author\'s name?');
	$args{abstract} //= prompt('Give a short description of this module:');
	$args{license} //= prompt('What license do you want to use?', 'Perl_5');

	my $license = get_license(delete $args{license}, $args{author});

	mkdir $args{dirname};
	chdir $args{dirname};
	($args{module_name} = $distname) =~ s/-/::/g; # 5.014 for s///r?

	write_module(%args, notice => $license->notice);
	write_license($license);
	write_changes(%args, distname => $distname);
	write_maniskip($distname);
	write_readme(%args, distname => $distname, notice => $license->notice);

	return;
}

__DATA__

@@ Changes
Revision history for {{ $distname }}

{{ $version }}
          - Initial release to an unsuspecting world

@@ README
This archive contains the distribution {{ $distname }}

  {{ $abstract }}
 
{{ $notice }}
 
This README file was generated by mbtiny
@@ Module.pm
package {{ $module_name }};

${{ $module_name}}::VERSION = '{{ $version }};

use strict;
use warnings;

{{ $end }}

=pod

=encoding utf-8

=head1 NAME

{{ $module_name }} - {{ $abstract }}

=head1 VERSION

{{ $version }}

=head1 DESCRIPTION

Write a full description of the module and its features here.

=head1 AUTHOR

{{ $author }}

=head1 COPYRIGHT AND LICENSE

{{ $notice }}

1;
