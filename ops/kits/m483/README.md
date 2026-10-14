# m483: baby step 4.8.3, the first timing pair (ADR-028) on the re-measured stack

New: ops/attested/m483-control.sh (the unwrapped control run), m483_metrics.py (the numbers of a run), m483-control-rehearse.sh.
Unchanged copies: m481r-run.sh (the wrapped run, as it ran for run 11), cluster-mode.sh and audit.sh (from branch tip 4ae2015).
Order of a pair: worker prepared; wrapped run (m481r-run.sh, receipts on); packs and measured-set check; plain mode on both nodes;
control run (m483-control.sh, receipts on); wrapped mode restored on both nodes; measured-set check again; metrics of both runs.
Unpacking drops the executable flag: run  chmod +x ~/m483kit/m483/ops/attested/*.sh  after unpacking.
