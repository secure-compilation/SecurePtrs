Require Import Common.Definitions.
Require Import Common.Values.
Require Import Tagging.Examples.Helper.
Require Import Source.Examples.DefaultInitBuffer.

Definition fuel := 1000%nat.
Definition to_run := compile_and_run_from_source_ex default_init_buffer fuel.

Set Warnings "-extraction-reserved-identifier".
Extraction "/tmp/run_mp_compiled_default_init_buffer.ml" to_run.
