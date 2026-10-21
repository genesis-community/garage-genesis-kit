# Shared helpers for the shape of a Garage cluster, meaning its instance
# count and its replication factor.  Hooks include them into their own
# package via:
#   do <hooks-dir>/lib/_garage_shape.pm
#
# The blueprint uses them to pick the default replication factor, and the
# check hook uses them to refuse unsafe shapes and unsafe changes against
# the exodus data of the last deploy.  _garage_shape_errors takes plain data
# and touches nothing else, so spec/hooks/shape.t can test it directly.

# _garage_default_rf - the replication factor a cluster of N nodes gets {{{
# Three copies once there are three nodes, and otherwise one copy per node.
sub _garage_default_rf {
	my ($instances) = @_;
	return 1 unless defined($instances) && $instances =~ /^[0-9]+$/ && $instances > 0;
	return $instances >= 3 ? 3 : $instances + 0;
}

# }}}
# _garage_truthy - read a boolean param that may arrive as a string {{{
sub _garage_truthy {
	my ($value) = @_;
	return 0 unless defined($value);
	return 0 if !ref($value) && $value =~ /^\s*(?:false|no|off|0|)\s*$/i;
	return $value ? 1 : 0;
}

# }}}
# _garage_ocfp_reserved - the garage reserved IPs in the OCFP subnets {{{
# Returns the garage_ip of every subnet under the env's prefix, in subnet
# order, with each subnet's AZ alongside, plus the first garage_ip_smoke.
sub _garage_ocfp_reserved {
	my ($self) = @_;
	return @{$self->{__garage_ocfp_reserved}} if $self->{__garage_ocfp_reserved};

	my $subnets = $self->env->ocfp_config_lookup('net.subnets');
	my $prefix  = $self->env->ocfp_subnet_prefix;
	my (@ips, @subnet_azs, $smoke_ip);
	for my $subnet (sort grep {/^$prefix/} keys %$subnets) {
		my $ip = $subnets->{$subnet}{'reserved-ips'}{'garage_ip'};
		next unless $ip;
		push @ips, $ip;
		push @subnet_azs, $subnets->{$subnet}{az};
		$smoke_ip //= $subnets->{$subnet}{'reserved-ips'}{'garage_ip_smoke'};
	}
	$self->{__garage_ocfp_reserved} = [\@ips, \@subnet_azs, $smoke_ip];
	return (\@ips, \@subnet_azs, $smoke_ip);
}

# }}}
# _garage_instance_count - how many garage nodes the manifest deploys {{{
# This follows the same order the manifest does.  Under ocfp the count is
# params.ocfp_instances or one node per reserved garage_ip.  Otherwise an
# explicit params.ips list sets it, and failing that params.instances, with
# a default of 3 for the cluster feature and 1 without it.
sub _garage_instance_count {
	my ($self) = @_;
	if ($self->want_feature('ocfp')) {
		my ($ips) = $self->_garage_ocfp_reserved;
		return scalar($self->env->lookup('params.ocfp_instances', undef)) || scalar(@$ips);
	}
	my $ips = scalar($self->env->lookup('params.ips', []));
	return scalar(@$ips) if ref($ips) eq 'ARRAY' && @$ips;
	return scalar($self->env->lookup('params.instances', undef))
		|| ($self->want_feature('cluster') ? 3 : 1);
}

# }}}
# _garage_replication_factor - the factor the manifest deploys {{{
# Returns the factor and whether the environment set it explicitly.
sub _garage_replication_factor {
	my ($self, $instances) = @_;
	my $rf = scalar($self->env->lookup('params.garage_replication_factor', undef));
	return ($rf, 1) if defined($rf) && $rf ne '';
	return (_garage_default_rf($instances), 0);
}

# }}}
# _garage_previous_shape - the shape the last deploy recorded in exodus {{{
# Returns undef when the environment has never been deployed.  Exodus data
# from an older kit holds neither the replication factor nor the instance
# count, so the count falls back to the deployed addresses and the factor
# to the old kit's default of 1.  An explicit factor in the environment file
# is taken as the one that kit deployed, since that kit honoured it too.
sub _garage_previous_shape {
	my ($self, $explicit_rf) = @_;
	my $exodus = scalar($self->env->exodus_lookup('.', undef));
	return undef unless ref($exodus) eq 'HASH' && %$exodus;

	my %previous;
	my $rf = $exodus->{replication_factor};
	if (defined($rf) && $rf =~ /^[0-9]+$/) {
		$previous{rf} = $rf + 0;
	} else {
		$previous{rf}        = defined($explicit_rf) ? $explicit_rf : 1;
		$previous{rf_legacy} = 1;
	}

	my $instances = $exodus->{instances};
	if (defined($instances) && $instances =~ /^[0-9]+$/) {
		$previous{instances} = $instances + 0;
	} else {
		my $ips = $exodus->{ips};
		$ips = [split /\s*,\s*/, $ips] if defined($ips) && !ref($ips);
		my @ips = grep {defined($_) && $_ ne ''} @{ref($ips) eq 'ARRAY' ? $ips : []};
		$previous{instances} = scalar(@ips) if @ips;
	}
	return \%previous;
}

# }}}
# _garage_shape_errors - every reason the shape is unsafe to deploy {{{
# Takes instances, rf, allow_rf1, allow_scale_down, and previous (the hash
# from _garage_previous_shape, or undef for a first deploy), and returns one
# message per problem.  An empty list means the shape may be deployed.
sub _garage_shape_errors {
	my (%shape) = @_;
	my ($instances, $rf, $previous) = @shape{qw/instances rf previous/};
	my @errors;

	unless (defined($rf) && $rf =~ /^[1-9][0-9]*$/) {
		return sprintf(
			"params.garage_replication_factor is %s, but it has to be a whole number of copies, 1 or more.",
			defined($rf) ? "'$rf'" : 'empty'
		);
	}
	unless (defined($instances) && $instances =~ /^[1-9][0-9]*$/) {
		return sprintf(
			"The kit could not work out how many garage instances this environment deploys (it got %s).",
			defined($instances) ? "'$instances'" : 'nothing'
		);
	}

	push @errors, sprintf(
		"params.garage_replication_factor is 1 on a cluster of %d nodes, so every object lives on " .
		"exactly one node, and losing that node or its disk loses the objects.  Garage cannot " .
		"change the factor once the cluster has a layout.  Remove the param to take the default " .
		"of %d, or set params.garage_allow_rf1: true to accept the risk.",
		$instances, _garage_default_rf($instances)
	) if $rf == 1 && $instances > 1 && !_garage_truthy($shape{allow_rf1});

	push @errors, sprintf(
		"params.garage_replication_factor is %d, but the environment deploys only %d garage %s, " .
		"and Garage needs at least one node per copy.  Lower the factor or add instances.",
		$rf, $instances, $instances == 1 ? 'instance' : 'instances'
	) if $rf > $instances;

	return @errors unless $previous;

	if (defined($previous->{rf}) && $previous->{rf} != $rf) {
		push @errors, $previous->{rf_legacy}
			? sprintf(
				"The last deploy came from a kit that did not record the replication factor, and " .
				"that kit defaulted it to 1.  This kit would deploy %d instead, and Garage refuses " .
				"to start a node whose factor differs from the one in its stored layout.  Set " .
				"params.garage_replication_factor to the factor the cluster runs today, which is 1 " .
				"unless the environment set it some other way, together with " .
				"params.garage_allow_rf1: true when there is more than one node.",
				$rf)
			: sprintf(
				"params.garage_replication_factor would change from %d to %d.  Garage refuses to " .
				"start a node whose factor differs from the one in its stored layout, so the deploy " .
				"would take the nodes down one at a time.  Set the factor back to %d.  A different " .
				"factor needs a new cluster, with the data copied across.",
				$previous->{rf}, $rf, $previous->{rf});
	}

	if (defined($previous->{instances}) && $previous->{instances} > 1 && $instances == 1) {
		push @errors, sprintf(
			"The garage instance count would drop from %d to 1.  A single instance runs Garage in " .
			"single-node mode, which refuses to start once the stored layout has moved past its " .
			"first version, as every cluster's layout has, so the last node would not come back.  " .
			"params.garage_allow_scale_down does not excuse this.  Keep at least two instances, or " .
			"build a new single-node deployment and copy the data across.",
			$previous->{instances}
		);
	} elsif (defined($previous->{instances}) && $instances < $previous->{instances}
		&& !_garage_truthy($shape{allow_scale_down})) {
		push @errors, sprintf(
			"The garage instance count would drop from %d to %d.  BOSH deletes the departing nodes " .
			"together with their persistent disks, and Garage loses every copy those disks hold.  " .
			"First run garage layout remove for each departing node, apply the layout with garage " .
			"layout apply, and wait until the resync has finished and garage status shows the " .
			"remaining nodes holding every partition.  Then lower instances and deploy with " .
			"params.garage_allow_scale_down: true.",
			$previous->{instances}, $instances
		);
	}

	return @errors;
}

# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
