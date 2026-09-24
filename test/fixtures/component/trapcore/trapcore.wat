;; A single core module whose start function traps. Instantiating it fails after
;; its instance table exists, so it is the baseline for how many tables one failed
;; instantiate leaves behind: the linker must not leave more than this.
(module
  (func $start
    (unreachable))
  (start $start))
