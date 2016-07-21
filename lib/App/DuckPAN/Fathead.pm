package App::DuckPAN::Fathead;
# ABSTRACT: Searches a given output.txt file for a query match

use Moo;
with 'App::DuckPAN::HasApp';

use DBI;
use JSON;
use Path::Tiny;
use HTML::TreeBuilder;
use HTML::Element;
use Data::Printer return_value => 'dump';

has selected => (
	is => 'rw',
	lazy => 1,
	required => 0,
	predicate => 1,
	trigger => 1
);

sub _trigger_selected {
	my ( $self, $id ) = @_;
	my $dir = path("lib/fathead/$id");
	unless ($dir->is_dir) {
		my $full_path = $dir->realpath;
		$self->app->emit_and_exit(1, "Directory not found: $full_path") ;
	}
	return $dir;
}

has output_txt => (
	is => 'rw',
	lazy => 1,
	required => 0,
	builder => 1
);

sub _build_output_txt {
	my ( $self ) = @_;
	my $file = undef;
	if ($self->has_selected) {
		$file = path("lib/fathead/", $self->selected, "/output.txt");
		unless ($file->exists){
			my $full_path = $file->realpath;
			$self->app->emit_and_exit(1, "No output.txt was not found in $full_path");
		}
	}
	return $file;
}

has dbh => (
	is => 'rw',
	lazy => 1,
	required => 0,
	builder => 1
);

sub _build_dbh {
	my ( $self ) = @_;

	# Open output.txt file for searching
	# Handles as a CSV with "\t" separator
	# Provide numbered column names
	my $dbh = DBI->connect ("dbi:CSV:", undef, undef, {
		f_dir                   => $self->output_txt->parent,
		f_ext                   => ".txt/r",
		csv_sep_char            => "\t",
		csv_quote_char          => undef,
		csv_escape_char         => undef,
		csv_allow_whitespace    => 1,
		csv_allow_quotes        => 1,
		RaiseError              => 1,
		PrintError              => 0,
		csv_tables => {
			output => {
				file => 'output.txt',
				col_names => [
					"title",
					"type",
					"redirect",
					"col4",
					"categories",
					"col6",
					"related_topics",
					"col8",
					"external_links",
					"disambiguation",
					"images",
					"abstract",
					"abstract_url",
				],
			},
		},
	}) or die $DBI::errstr;

	return $dbh;
}

has result => (
	is => 'rw',
	lazy => 1,
	required => 0,
	predicate => 1
);

# Get a Fathead result from the DB
# Requery when we get a Redirect
sub search_output {

	my ($self, $query) = @_;

	my $result = $self->_db_lookup($query);

	if ($result && $result->{type} eq "R") {
		my $redirect = $result->{redirect};
		$result = $self->_db_lookup($redirect);
		$self->app->emit_notice("Following Redirect: '$query' -> '$redirect'");
	}

	$self->result($result) if $result;
	return $self->has_result;
}

# Attempt to get a result from DB (output.txt)
# Capture & display any raised errors
sub _db_lookup {
	my ($self, $query) = @_;

	my $result;
	$@ = '';

	eval {
		# TODO lowercase all titles first
		my $sth = $self->dbh->prepare("SELECT * FROM output WHERE lower(title) = ?");
		$sth->execute(lc $query);
		while (my $row = $sth->fetchrow_hashref) {
			$result = $row;
		}
		$sth->finish();
	};
	$self->app->emit_error("SQL database error: $@") if $@;
	return $result;
}

# Build a Structured Answer hash
# Properties depend on Fathead result type
sub get_structured_answer {
	my ($self) = @_;

	# Get IA Metadata via ID lookup
	# Assume selected is an ID
	my $metadata = DDG::Meta::Data->get_ia(id => $self->selected) // {};
	$self->app->emit_error("No Metadata found for ID: ".$self->selected) unless keys $metadata;
	my $data = $self->result;

	# DBD::Csv ignores col_names letter casing
	# So, manually map columns to template properties
	# TODO update info_detail template to use lowercase variable names
	my %extra_data;

	my $out = {
		id => $self->selected,
		signal => "high",
		meta => $metadata,
	};

	# Article Result
	if ($data->{type} eq 'A') {
		$out->{duckbar_topic} = 'About';
		$out->{model} = 'FatheadArticle';
		$out->{templates} = { detail => 'info_detail' };
		%extra_data = (
			Heading 	=> $data->{title},
			Abstract 	=> $self->_replace_newlines($data->{abstract}),
			AbstractURL => $data->{abstract_url},
			FirstURL 	=> $metadata->{src_url},
			Image 		=> $self->_get_image($data->{images}),
		);
	}

	# Disambiguation Result
	if ($data->{type} eq 'D') {
		$out->{duckbar_topic} = 'Meanings';
		$out->{model} = 'FatheadListItem';
		$out->{templates} = { item => 'meanings_item' };
		%extra_data = (
			Heading 	=> $data->{title}." (".$metadata->{name}.")",
			RelatedTopics => $self->_get_related_topics($data->{disambiguation}, $out)
		);
	}

	# Category Pages Result
	if ($data->{type} eq 'C') {
		$out->{duckbar_topic} = 'List';
		$out->{model} = 'FatheadListItem';
		$out->{templates} = { item => 'categories_item' };
	}

	$out->{data} = { %$data, %extra_data };
	return $out;
}

# Emulate internal processing to build JSON
# matching DDG API result format
sub _get_related_topics {
	my ($self, $disambiguations, $out) = @_;
	my @related_topics;
	my @disambiguations = split /\\n/, $disambiguations;
	foreach my $disambiguation (@disambiguations){
		my $result = {};
		if ($disambiguation =~ m/^\*\[\[(\w+)\]\],(.+)$/) {
			my $title = $1;
			my $html  = $2;

			# Parse HTML into plaintext
			my $root = HTML::TreeBuilder->new_from_content($html);
			$root->elementify();
			my $text = $root->as_trimmed_text;

			# Build URL Path
			my $href = "/".$out->{meta}->{src_id}."/$title";
			my $a = HTML::Element->new('a', href => $href);
			$a->push_content($title);

			$result = {
				Result => $a->as_HTML . "$text",    # generates `<a href="$url">$title</a>$text` which gets parsed by template helpers
				FirstURL => $href,
				Text => $text
			};
		}
		push @related_topics, $result;
	}
	return \@related_topics;
}

# Emulate internal processing to build JSON
# matching DDG API result format
sub _get_image {
	my ($self, $image) = @_;
	my $url = "";
	if ($image =~ m/^\[\[Image:(.+)\]\]$/) {
		$url = $1;
	}
	return $url;
}


sub _replace_newlines {
	my ($self, $abstract) = @_;
	$abstract =~ s/\\n/<br>/g;
	return $abstract;
}


1;
