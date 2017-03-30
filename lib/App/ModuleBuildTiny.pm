package App::ModuleBuildTiny;

use 5.010;
use strict;
use warnings;
our $VERSION = '0.018';

use Exporter 5.57 'import';
our @EXPORT = qw/modulebuildtiny/;

use Carp qw/croak/;
use Config;
use CPAN::Meta;
use Data::Section::Simple 'get_data_section';
use Encode qw/encode_utf8 decode_utf8/;
use ExtUtils::Manifest qw/manifind maniskip maniread/;
use File::Basename qw/basename dirname/;
use File::Copy qw/copy/;
use File::Path qw/mkpath rmtree/;
use File::Slurper qw/write_text write_binary read_binary/;
use File::Spec::Functions qw/catfile catdir rel2abs/;
use Getopt::Long 2.36 'GetOptionsFromArray';
use JSON::PP qw/encode_json decode_json/;
use Module::Runtime 'require_module';
use Pod::Simple::Text 3.23;
use Text::Template;

use Env qw/$AUTHOR_TESTING $RELEASE_TESTING $AUTOMATED_TESTING $SHELL @PERL5LIB @PATH $HOME $USERPROFILE/;

sub prereqs_for {
	my ($meta, $phase, $type, $module, $default) = @_;
	return $meta->effective_prereqs->requirements_for($phase, $type)->requirements_for_module($module) || $default || 0;
}

sub generate_readme {
	my $distname = shift;
	(my $filename = "lib/$distname.pm") =~ s{-}{/};
	croak "Main module file $filename doesn't exist" if not -f $filename;
	my $parser = Pod::Simple::Text->new;
	$parser->output_string( \my $content );
	$parser->parse_characters(1);
	$parser->parse_file($filename);
	return $content;
}

sub get_files {
	my %opts = @_;
	my $files;
	if (not $opts{regenerate}{MANIFEST} and -r 'MANIFEST') {
		$files = maniread;
	}
	else {
		my $maniskip = maniskip;
		$files = manifind();
		delete $files->{$_} for grep { $maniskip->($_) } keys %$files;
	}
	delete $files->{$_} for keys %{ $opts{regenerate} };
	
	my $dist_name = $opts{meta}->name;
	$files->{'Build.PL'} //= do {
		my $minimum_mbt  = prereqs_for($opts{meta}, qw/configure requires Module::Build::Tiny/);
		my $minimum_perl = prereqs_for($opts{meta}, qw/runtime requires perl 5.006/);
		"# This Build.PL for $dist_name was generated by mbtiny $VERSION.\nuse $minimum_perl;\nuse Module::Build::Tiny $minimum_mbt;\nBuild_PL();\n";
	};
	$files->{'META.json'} //= $opts{meta}->as_string;
	$files->{'META.yml'} //= $opts{meta}->as_string({ version => 1.4 });
	$files->{LICENSE} //= $opts{license}->fulltext;
	$files->{README} //= generate_readme($dist_name);
	# This must come last
	$files->{MANIFEST} //= join '', map { "$_\n" } sort keys %$files;

	return $files;
}

sub uptodate {
	my ($destination, @source) = @_;
	return if not -e $destination;
	for my $source (grep { defined && -e } @source) {
		return if -M $destination < -M $source;
	}
	return 1;
}

sub find {
	my ($re, @dir) = @_;
	my $ret;
	File::Find::find(sub { $ret++ if /$re/ }, @dir);
	return $ret;
}

sub mbt_version {
	if (find(qr/\.PL$/, 'lib')) {
		return '0.039';
	}
	elsif (find(qr/\.xs$/, 'lib')) {
		return '0.036';
	}
	return '0.034';
}

sub load_mergedata {
	my $mergefile = shift;
	if (defined $mergefile and -r $mergefile) {
		require Parse::CPAN::Meta;
		return Parse::CPAN::Meta->load_file($mergefile);
	}
	return;
}

sub distname {
	my $extra = shift;
	return delete $extra->{name} if defined $extra->{name};
	my $distname = basename(rel2abs('.'));
	$distname =~ s/(?:^(?:perl|p5)-|[\-\.]pm$)//x;
	return $distname;
}

sub detect_license {
	my ($data, $filename, $authors) = @_;
	my (@license_sections) = grep { /licen[cs]e|licensing|copyright|legal|authors?\b/i } $data->pod_inside;
	for my $license_section (@license_sections) {
		next unless defined ( my $license_pod = $data->pod($license_section) );
		require Software::LicenseUtils;
		my $content = "=head1 LICENSE\n" . $license_pod;
		my @guess = Software::LicenseUtils->guess_license_from_pod($content);
		next if not @guess;
		croak "Couldn't parse license from $license_section in $filename: @guess" if @guess != 1;
		my $class = $guess[0];
		my ($year) = $license_pod =~ /.*? copyright .*? ([\d\-]+)/;
		require_module($class);
		return $class->new({holder => join(', ', @{$authors}), year => $year});
	}
	croak "No license found in $filename";
}

sub get_meta {
	my %opts = @_;
	my $mergefile = $opts{mergefile} || (grep { -f } qw/metamerge.json metamerge.yml/)[0];
	my $mergedata = load_mergedata($mergefile) || {};
	my $distname = distname($mergedata);
	my $filename = catfile('lib', split /-/, $distname) . '.pm';

	require Module::Metadata;
	my $data = Module::Metadata->new_from_file($filename, collect_pod => 1) or die "Couldn't analyse $filename: $!";
	my @authors = map { / \A \s* (.+?) \s* \z /x } grep { /\S/ } split /\n/, $data->pod('AUTHOR') // '' or warn "Could not parse any authors from `=head1 AUTHOR` in $filename";

	if (not %{ $opts{regenerate} || {} } and uptodate('META.json', 'cpanfile', $mergefile)) {
		return (CPAN::Meta->load_file('META.json', { lazy_validation => 0 }), detect_license($data, $filename, \@authors));
	}
	else {
		my ($abstract) = ($data->pod('NAME') // '')  =~ / \A \s+ \S+ \s? - \s? (.+?) \s* \z /x or warn "Could not parse abstract from `=head1 NAME` in $filename";
		my $version = $data->version($data->name) // die "Cannot parse \$VERSION from $filename";

		my $license = detect_license($data, $filename, \@authors);

		my $prereqs = -f 'cpanfile' ? do { require Module::CPANfile; Module::CPANfile->load('cpanfile')->prereq_specs } : {};
		$prereqs->{configure}{requires}{'Module::Build::Tiny'} //= mbt_version();
		$prereqs->{develop}{requires}{'App::ModuleBuildTiny'} //= $VERSION;

		my $metahash = {
			name           => $distname,
			version        => $version->stringify,
			author         => \@authors,
			abstract       => $abstract,
			dynamic_config => 0,
			license        => [ $license->meta2_name ],
			prereqs        => $prereqs,
			release_status => $version =~ /_|-TRIAL$/ ? 'testing' : 'stable',
			generated_by   => "App::ModuleBuildTiny version $VERSION",
			'meta-spec'    => {
				version    => '2',
				url        => 'http://search.cpan.org/perldoc?CPAN::Meta::Spec'
			},
		};
		if (%{$mergedata}) {
			require CPAN::Meta::Merge;
			$metahash = CPAN::Meta::Merge->new(default_version => '2')->merge($metahash, $mergedata);
		}
		$metahash->{provides} ||= Module::Metadata->provides(version => 2, dir => 'lib') if not $metahash->{no_index};
		return (CPAN::Meta->create($metahash, { lazy_validation => 0 }), $license);
	}
}

Getopt::Long::Configure(qw/require_order pass_through gnu_compat/);

sub distdir {
	my %opts    = @_;
	my ($meta, $license) = get_meta();
	my $dir     = $opts{dir} || $meta->name . '-' . $meta->version;
	mkpath($dir, $opts{verbose}, oct '755');
	my $content = get_files(%opts, meta => $meta, license => $license);
	for my $filename (keys %{$content}) {
		my $target = catfile($dir, $filename);
		mkpath(dirname($target)) if not -d dirname($target);
		if ($content->{$filename}) {
			write_text($target, $content->{$filename});
		}
		else {
			copy($filename, $target);
		}
	}
}

sub checkchanges {
	my $version = quotemeta shift;
	open my $changes, '<:raw', 'Changes' or die "Couldn't open Changes file";
	my (undef, @content) = grep { / ^ $version (?:-TRIAL)? (?:\s+|$) /x ... /^\S/ } <$changes>;
	pop @content while @content && $content[-1] =~ / ^ (?: \S | \s* $ ) /x;
	warn "Changes appears to be empty\n" if not @content
}

my $Build = $^O eq 'MSWin32' ? 'Build' : './Build';

sub run {
	my %opts = @_;
	require File::Temp;
	my $dir  = File::Temp::tempdir(CLEANUP => 1);
	distdir(%opts, dir => $dir);
	chdir $dir;
	if ($opts{build}) {
		system $Config{perlpath}, 'Build.PL';
		system $Build, 'build';
		unshift @PERL5LIB, map { rel2abs(catdir('blib', $_)) } 'arch', 'lib';
		unshift @PATH, rel2abs(catdir('blib', 'script'));
	}
	return system @{ $opts{command} };
}

sub prompt {
	my($mess, $def) = @_;

	my $dispdef = defined $def ? " [$def]" : "";

	local $|=1;
	local $\;
	print "$mess$dispdef ";

	my $ans = <STDIN> // '';
	chomp $ans;
	return $ans ne '' ? decode_utf8($ans) : $def // '';
}

sub create_license_for {
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
	$template =~ s/ ^ % (\w+) /=$1/gxms;
	my $filename = catfile('lib', split /::/, $opts{module_name}) . '.pm';
	my $content = fill_in($template, \%opts);
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
	write_text('MANIFEST.SKIP', "#!include_default\n$distname-.*\nREADME.pod\n");
	maniskip(); # This expands the #!include_default as a side-effect
	unlink 'MANIFEST.SKIP.bak' if -f 'MANIFEST.SKIP.bak';
}

sub write_readme {
	my %opts = @_;
	my $template = get_data_section('README');
	write_text('README', fill_in($template, \%opts));
}

sub get_home {
	local $HOME = $USERPROFILE if $^O eq 'MSWin32';
	return glob '~';
}

sub get_config {
	return catfile(get_home(), qw/.mbtiny conf/);
}

sub read_json {
	my $filename = shift;
	-f $filename or return;
	return decode_json(read_binary($filename));
}

sub write_json {
	my ($filename, $content) = @_;
	my $dirname = dirname($filename);
	mkdir $dirname if not -d $dirname;
	return write_binary($filename, encode_json($content));
}

my @config_items = (
	[ 'author'  , 'What is the author\'s name?' ],
	[ 'email'   , 'What is the author\'s email?' ],
	[ 'license' , 'What license do you want to use?', 'Perl_5' ],
);

my %actions = (
	dist => sub {
		my @arguments = @_;
		GetOptionsFromArray(\@arguments, 'verbose!' => \my $verbose);
		require Archive::Tar;
		my $arch    = Archive::Tar->new;
		my ($meta, $license) = get_meta();
		my $name    = $meta->name . '-' . $meta->version;
		checkchanges($meta->version);
		my $content = get_files(meta => $meta, license => $license);
		for my $filename (keys %{$content}) {
			if ($content->{$filename}) {
				$arch->add_data($filename, encode_utf8($content->{$filename}));
			}
			else {
				$arch->add_data($filename, read_binary($filename));
			}
		}
		$_->mode($_->mode & ~oct 22) for $arch->get_files;
		printf "tar czf $name.tar.gz %s\n", join ' ', keys %{$content} if ($verbose || 0) > 0;
		$arch->write("$name.tar.gz", &Archive::Tar::COMPRESS_GZIP, $name);
		return 0;
	},
	distdir => sub {
		my @arguments = @_;
		GetOptionsFromArray(\@arguments, 'verbose!' => \my $verbose);
		distdir(verbose => $verbose);
		return 0;
	},
	test => sub {
		my @arguments = @_;
		$AUTHOR_TESTING = 1;
		GetOptionsFromArray(\@arguments, 'release!' => \$RELEASE_TESTING, 'author!' => \$AUTHOR_TESTING, 'automated!' => \$AUTOMATED_TESTING);
		return run(command => [ $Build, 'test' ], build => 1);
	},
	run => sub {
		my @arguments = @_;
		croak "No arguments given to run" if not @arguments;
		GetOptionsFromArray(\@arguments, 'build!' => \(my $build = 1));
		return run(command => \@arguments, build => $build);
	},
	shell => sub {
		my @arguments = @_;
		GetOptionsFromArray(\@arguments, 'build!' => \my $build);
		return run(command => [ $SHELL ], build => $build);
	},
	listdeps => sub {
		my @arguments = @_;
		GetOptionsFromArray(\@arguments, \my %opts, qw/json only_missing|only-missing|missing omit_core|omit-core=s author versions/);
		my ($meta) = get_meta();

		require CPAN::Meta::Prereqs::Filter;
		my $prereqs = CPAN::Meta::Prereqs::Filter::filter_prereqs($meta->effective_prereqs, %opts, sanitize => 1);

		if (!$opts{json}) {
			my @phases = qw/build test configure runtime/;
			push @phases, 'develop' if $opts{author};

			my $reqs = $prereqs->merged_requirements(\@phases);
			$reqs->clear_requirement('perl');

			my @modules = sort { lc $a cmp lc $b } $reqs->required_modules;
			if ($opts{versions}) {
				say "$_ = ", $reqs->requirements_for_module($_) for @modules;
			}
			else {
				say for @modules;
			}
		}
		else {
			require JSON::PP;
			print JSON::PP->new->ascii->pretty->encode($prereqs->as_string_hash);
		}
		return 0;
	},
	regenerate => sub {
		my @arguments = @_;
		my %files = map { $_ => 1 } @arguments ? @arguments : qw/Build.PL META.json META.yml MANIFEST LICENSE README/;

		my ($meta, $license) = get_meta(regenerate => \%files);
		my $content = get_files(meta => $meta, regenerate => \%files, license => $license);
		for my $filename (keys %files) {
			mkpath(dirname($filename)) if not -d dirname($filename);
			write_text($filename, $content->{$filename}) if $content->{$filename};
		}
		return 0;
	},
	configure => sub {
		my @arguments = @_;
		my $home = get_home;
		my $config_file = catfile($home, qw/.mbtiny conf/);

		my $mode = @arguments ? $arguments[0] : 'upgrade';

		if ($mode eq 'upgrade') {
			my $config = -f $config_file ? read_json($config_file) : {};
			for my $item (@config_items) {
				my ($key, $description, $default) = @{$item};
				next if defined $config->{$key};
				$config->{$key} = prompt($description, $default);
			}
			write_json($config_file, $config);
		}
		elsif ($mode eq 'all') {
			my $config = {};
			for my $item (@config_items) {
				my ($key, $description, $default) = @{$item};
				$config->{$key} = prompt($description, $default);
			}
			write_json($config_file, $config);
		}
		elsif ($mode eq 'reset') {
			return not unlink $config_file;
		}
		return 0;
	},
	mint => sub {
		my @arguments = @_;

		my $config_file = get_config();
		croak "No config file present, please run mbtiny configure" if not -f $config_file;
		my $config = read_json($config_file);
		croak "Config not readable, please run mbtiny configure" if not defined $config;

		my $distname = decode_utf8(shift @arguments || croak 'No distribution name given');
		croak "Directory $distname already exists" if -e $distname;

		my %args = (
			%{ $config },
			version => '0.001',
			dirname => $distname,
		);
		GetOptionsFromArray(\@arguments, \%args, qw/author=s email=s version=s abstract=s license=s dirname=s/);

		my $license = create_license_for(delete $args{license}, $args{author});

		mkdir $args{dirname};
		chdir $args{dirname};
		($args{module_name} = $distname) =~ s/-/::/g; # 5.014 for s///r?

		write_module(%args, notice => $license->notice);
		write_text('LICENSE', $license->fulltext);
		write_changes(%args, distname => $distname);
		write_maniskip($distname);

		return 0;
	},
);

sub modulebuildtiny {
	my ($action, @arguments) = @_;
	croak 'No action given' unless defined $action;
	my $call = $actions{$action};
	croak "No such action '$action' known\n" if not $call;
	return $call->(@arguments);
}

1;

=head1 NAME

App::ModuleBuildTiny - A standalone authoring tool for Module::Build::Tiny

=head1 VERSION

version 0.018

=head1 DESCRIPTION

App::ModuleBuildTiny contains the implementation of the L<mbtiny> tool.

=head1 FUNCTIONS

=over 4

=item * modulebuildtiny($action, @arguments)

This function runs a modulebuildtiny command. It expects at least one argument: the action. It may receive additional ARGV style options dependent on the command.

The actions are documented in the L<mbtiny> documentation.

=back

=head1 SEE ALSO

=head2 Helpers

=over 4

=item * L<scan-prereqs-cpanfile|scan-prereqs-cpanfile>

A tool to automatically generate a L<cpanfile> for you.

=item * L<cpan-upload|cpan-upload>

A program that facilitates upload the tarball as produced by C<mbtiny>.

=item * L<perl-reversion|perl-reversion>

A tool to bump the version in your modules.

=item * L<perl-bump-version|perl-bump-version>

An alternative tool to bump the version in your modules

=back

=head2 Similar programs

=over 4

=item * L<Dist::Zilla|Dist::Zilla>

An extremely powerful but somewhat heavy authoring tool.

=item * L<Minilla|Minilla>

A more minimalistic but still somewhat customizable authoring tool.

=back

=head1 AUTHOR

Leon Timmermans <leont@cpan.org>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2011 by Leon Timmermans.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut

__DATA__

@@ Changes
Revision history for {{ $distname }}

{{ $version }}
          - Initial release to an unsuspecting world

@@ Module.pm
package {{ $module_name }};

use strict;
use warnings;

our $VERSION = '{{ $version }}';

1;

{{ '__END__' }}

%pod

%encoding utf-8

%head1 NAME

{{ $module_name }} - {{ $abstract }}

%head1 VERSION

{{ $version }}

%head1 DESCRIPTION

Write a full description of the module and its features here.

%head1 AUTHOR

{{ $author }} <{{ $email }}>

%head1 COPYRIGHT AND LICENSE

{{ $notice }}

