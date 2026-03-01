#!/usr/bin/env perl
# make-test-data.pl — generates a NerfJournal import file for the current month.
#
# Outputs JSON to stdout; redirect to a file and import via Debug > Import:
#   perl make-test-data.pl > test-data.json
#
# Produces 14 journal pages spread across the current month with a mix of
# done, abandoned, migrated, and pending todos in a few group categories.
# Output is deterministic (fixed srand seed) so you get the same task
# assignments on every run.

use strict;
use warnings;
use POSIX       qw(strftime);
use Time::Local qw(timelocal);
use JSON::PP;

srand(20260228);  # fixed seed — change to get different task assignments

my @now   = localtime time;
my $year  = $now[5] + 1900;
my $month = $now[4] + 1;

# 14 days spread through the month, simulating skipped weekends and absences.
# All <= 22, so valid in any calendar month.
my @DAYS = (1, 2, 4, 5, 7, 8, 10, 11, 13, 14, 16, 18, 20, 22);

# Task pool: [title, group_or_undef, should_migrate]
# should_migrate: 1 = carries forward if left pending; 0 = abandoned instead
my @POOL = (
    [ 'Review sprint board',           undef,         0 ],
    [ 'Code review: auth PR',          'Engineering', 0 ],
    [ 'Fix flaky CI tests',            'Engineering', 1 ],
    [ 'Deploy hotfix to staging',      'Engineering', 1 ],
    [ 'Write migration guide',         'Engineering', 1 ],
    [ 'Update API docs',               'Engineering', 1 ],
    [ '1:1 with Alice',                'Meetings',    0 ],
    [ 'Sprint planning',               'Meetings',    0 ],
    [ 'Retrospective',                 'Meetings',    0 ],
    [ 'Respond to Slack backlog',      undef,         0 ],
    [ 'Update Jira tickets',           undef,         0 ],
    [ 'Review infrastructure costs',   undef,         1 ],
    [ 'Profile slow dashboard query',  'Engineering', 1 ],
    [ 'Refactor auth middleware',      'Engineering', 1 ],
    [ 'Write weekly summary',          undef,         0 ],
    [ 'Investigate memory leak',       'Engineering', 1 ],
    [ 'Code review: search PR',        'Engineering', 0 ],
    [ 'Schedule 1:1 with Bob',         'Meetings',    0 ],
    [ 'Post-mortem writeup',           undef,         1 ],
    [ 'Set up new dev environment',    'Engineering', 1 ],
);

# -- helpers -----------------------------------------------------------------

sub iso8601 { strftime('%Y-%m-%dT%H:%M:%SZ', gmtime($_[0])) }

sub day_ts {
    # Unix timestamp for midnight local time on day $d of the current month.
    timelocal(0, 0, 0, $_[0], $month - 1, $year - 1900);
}

# -- generation --------------------------------------------------------------

my (@pages_out, @todos_out, @notes_out);
my ($page_id, $todo_id, $note_id) = (1, 1, 1);

# Each element: [$title, $group, $migrate, $first_added_ts]
my @carry  = ();
my $pool_i = 0;

for my $pi (0 .. $#DAYS) {
    my $day     = $DAYS[$pi];
    my $is_last = ($pi == $#DAYS);
    my $page_ts = day_ts($day);

    push @pages_out, { id => $page_id, date => iso8601($page_ts) };
    my $cur_pid = $page_id++;

    my $sort = 0;
    my @next_carry;

    # --- carried-over todos from the previous page --------------------------
    for my $ct (@carry) {
        my ($title, $group, $migrate, $first_ts) = @$ct;

        my $status;
        if ($is_last) {
            $status = 'pending';
        } elsif ($migrate && rand() < 0.35) {
            $status = 'migrated';
            push @next_carry, $ct;
        } else {
            $status = 'done';
        }

        my $cur_tid = $todo_id;
        push @todos_out, {
            id             => $todo_id++,
            pageID         => $cur_pid,
            title          => $title,
            shouldMigrate  => $migrate ? JSON::PP::true : JSON::PP::false,
            status         => $status,
            sortOrder      => $sort++,
            groupName      => $group,
            externalURL    => undef,
            firstAddedDate => iso8601($first_ts),
        };
        if ($status eq 'done') {
            push @notes_out, {
                id            => $note_id++,
                pageID        => $cur_pid,
                timestamp     => iso8601($page_ts + 3600 * $sort),
                text          => undef,
                relatedTodoID => $cur_tid,
            };
        }
    }

    # --- new todos for this page --------------------------------------------
    my $new_count = 3 + int(rand 3);    # 3–5 fresh tasks
    for (1 .. $new_count) {
        my ($title, $group, $migrate) = @{ $POOL[$pool_i++ % @POOL] };

        my $status;
        if ($is_last) {
            $status = 'pending';
        } elsif (!$migrate && rand() < 0.12) {
            $status = 'abandoned';
        } elsif ($migrate && rand() < 0.28) {
            $status = 'migrated';
            push @next_carry, [$title, $group, $migrate, $page_ts];
        } else {
            $status = 'done';
        }

        my $cur_tid = $todo_id;
        push @todos_out, {
            id             => $todo_id++,
            pageID         => $cur_pid,
            title          => $title,
            shouldMigrate  => $migrate ? JSON::PP::true : JSON::PP::false,
            status         => $status,
            sortOrder      => $sort++,
            groupName      => $group,
            externalURL    => undef,
            firstAddedDate => iso8601($page_ts),
        };
        if ($status eq 'done') {
            push @notes_out, {
                id            => $note_id++,
                pageID        => $cur_pid,
                timestamp     => iso8601($page_ts + 3600 * $sort),
                text          => undef,
                relatedTodoID => $cur_tid,
            };
        }
    }

    @carry = @next_carry;
}

# -- output ------------------------------------------------------------------

my %export = (
    version      => 1,
    exportedAt   => iso8601(time),
    taskBundles  => [],
    bundleTodos  => [],
    journalPages => \@pages_out,
    todos        => \@todos_out,
    notes        => \@notes_out,
);

print JSON::PP->new->utf8->pretty->canonical->encode(\%export), "\n";
