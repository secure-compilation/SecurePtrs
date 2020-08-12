Require Import Common.Definitions.
Require Import Common.Values.
Require Import Transitional.
Require Import Source.Examples.NestedCalls.

Definition fuel := 1000%nat.
Definition to_run := compile_and_run_from_source_ex nested_calls fuel.

Set Warnings "-extraction-reserved-identifier".
Extraction "/tmp/run_mp_compiled_nested_calls.ml" to_run.
