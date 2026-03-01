#!/usr/bin/env perl
# make-test-data.pl — generates a NerfJournal import file for the current month.
#
# Outputs JSON to stdout; redirect to a file and import via Debug > Import:
#   perl make-test-data.pl > test-data.json
#
# Produces 14 journal pages spread across the current month. Each task is
# a single todo record with an "added" date and an optional "ending" (done
# or abandoned with a timestamp). A note is created on the page where a task
# was completed. Todos with no ending are still-pending at the close of the
# generated data. Output is deterministic (fixed srand seed) so you get the
# same task assignments on every run.

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
# should_migrate: 1 = stays pending on future pages if not done; 0 = abandoned
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

# Active pool: todos still pending at end of each day.
# Each entry: { id, migrate, added_ts }
my @active  = ();
my $pool_i  = 0;

for my $pi (0 .. $#DAYS) {
    my $day     = $DAYS[$pi];
    my $is_last = ($pi == $#DAYS);
    my $page_ts = day_ts($day);

    push @pages_out, { id => $page_id, date => iso8601($page_ts) };
    my $cur_pid = $page_id++;

    # --- resolve active (carried-over) todos --------------------------------
    my @still_active;
    for my $t (@active) {
        if ($is_last || ($t->{migrate} && rand() < 0.35)) {
            push @still_active, $t;    # carries forward to next day
        } else {
            # Completed on this page.
            my $done_ts = $page_ts + 3600;
            $todos_out[ $t->{id} - 1 ]{ending} = {
                date => iso8601($done_ts),
                kind => 'done',
            };
            push @notes_out, {
                id            => $note_id++,
                pageID        => $cur_pid,
                timestamp     => iso8601($done_ts),
                text          => undef,
                relatedTodoID => $t->{id},
            };
        }
    }
    @active = @still_active;

    # --- add new todos for this page ----------------------------------------
    my $new_count = 3 + int(rand 3);    # 3–5 fresh tasks per day
    for (1 .. $new_count) {
        my ($title, $group, $migrate) = @{ $POOL[$pool_i++ % @POOL] };
        my $cur_tid = $todo_id++;
        my $ending;

        if ($is_last) {
            # Last page: everything stays pending.
        } elsif (!$migrate && rand() < 0.12) {
            $ending = { date => iso8601($page_ts + 3600), kind => 'abandoned' };
        } elsif ($migrate && rand() < 0.28) {
            push @active, { id => $cur_tid, migrate => $migrate };
        } else {
            $ending = { date => iso8601($page_ts + 3600), kind => 'done' };
        }

        push @todos_out, {
            id            => $cur_tid,
            title         => $title,
            shouldMigrate => $migrate ? JSON::PP::true : JSON::PP::false,
            added         => iso8601($page_ts),
            ending        => $ending,
            groupName     => $group,
            externalURL   => undef,
        };

        if (defined($ending) && $ending->{kind} eq 'done') {
            push @notes_out, {
                id            => $note_id++,
                pageID        => $cur_pid,
                timestamp     => iso8601($page_ts + 3600),
                text          => undef,
                relatedTodoID => $cur_tid,
            };
        }
    }
}

# -- output ------------------------------------------------------------------

my %export = (
    version      => 2,
    exportedAt   => iso8601(time),
    taskBundles  => [],
    bundleTodos  => [],
    journalPages => \@pages_out,
    todos        => \@todos_out,
    notes        => \@notes_out,
);

print JSON::PP->new->utf8->pretty->canonical->encode(\%export), "\n";
