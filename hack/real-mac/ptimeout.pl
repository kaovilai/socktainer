# usage: perl ptimeout.pl SECS cmd args...  — kills the child hard after SECS (podman ignores SIGALRM)
my $secs = shift @ARGV;
my $pid = fork();
if (!$pid) { exec @ARGV or exit 127 }
$SIG{ALRM} = sub { kill 9, $pid; print STDERR "TIMEOUT\n"; exit 124 };
alarm $secs;
waitpid $pid, 0;
exit($? >> 8);
