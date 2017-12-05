Require Import Common.Definitions.
Require Import Common.Values.
Require Import Source.Examples.Helper.

Import Source.

(* naive factorial *)

Definition factorial : program := {|
  prog_interface :=
    mkfmap [(1, {| Component.import := fset [(2, 1)];
                   Component.export := fset [1] |});
            (2, {| Component.import := fset [];
                   Component.export := fset [1] |})];
  prog_buffers :=
    mkfmap [(1, inl 1); (2, inl 1)];
  prog_procedures :=
    mkfmap [
      (1, mkfmap [
        (1, E_call 2 1 (E_val (Int 6)))]);
      (2, mkfmap [
        (1, E_if (E_binop Leq (E_deref E_local) (E_val (Int 1)))
                 (E_val (Int 1))
                 (E_binop Mul
                          (E_deref E_local)
                          (E_call 2 1 (E_binop Minus (E_deref E_local) (E_val (Int 1))))))])];
  prog_main := Some (1, 1)
|}.

Definition fuel := 1000.
Definition to_run := run factorial fuel.

Extraction "/tmp/run_fact.ml" to_run.