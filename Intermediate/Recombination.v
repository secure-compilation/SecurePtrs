Require Import Common.Definitions.
Require Import Common.Util.
Require Import Common.Memory.
Require Import Common.Linking.
Require Import Common.CompCertExtensions.
Require Import CompCert.Events.
Require Import CompCert.Smallstep.
Require Import CompCert.Behaviors.
Require Import Intermediate.Machine.
Require Import Intermediate.GlobalEnv.
Require Import Intermediate.CS.
Require Import Intermediate.PS.
Require Import Intermediate.Decomposition.
Require Import Intermediate.Composition.

Require Import Coq.Program.Equality.

From mathcomp Require Import ssreflect ssrfun ssrbool.

Set Implicit Arguments.
Unset Strict Implicit.
Unset Printing Implicit Defensive.

Set Bullet Behavior "Strict Subproofs".

Import Intermediate.

Section BehaviorStar.
  Variables p c: program.

  Hypothesis wf1 : well_formed_program p.
  Hypothesis wf2 : well_formed_program c.

  Hypothesis mergeable_interfaces:
    mergeable_interfaces (prog_interface p) (prog_interface c).

  (* Hypothesis linkability: linkable (prog_interface p) (prog_interface c). *)
  Hypothesis main_linkability: linkable_mains p c.

  Hypothesis prog_is_closed:
    closed_program (program_link p c).

  (* RB: Could be phrased in terms of does_prefix. *)
  Theorem behavior_prefix_star b m :
    program_behaves (CS.sem (program_link p c)) b ->
    prefix m b ->
  exists s1 s2,
    CS.initial_state (program_link p c) s1 /\
    Star (CS.sem (program_link p c)) s1 (finpref_trace m) s2.
  Admitted.
End BehaviorStar.

Section Recombination.
  Variables p c p' c' : program.

  Hypothesis Hwfp  : well_formed_program p.
  Hypothesis Hwfc  : well_formed_program c.
  Hypothesis Hwfp' : well_formed_program p'.
  Hypothesis Hwfc' : well_formed_program c'.

  Variables ip ic : Program.interface.

  Hypothesis Hmergeable_ifaces: mergeable_interfaces ip ic.

  Hypothesis Hifacep  : prog_interface p  = ip.
  Hypothesis Hifacec  : prog_interface c  = ic.
  Hypothesis Hifacep' : prog_interface p' = ip.
  Hypothesis Hifacec' : prog_interface c' = ic.

  (* RB: TODO: Simplify redundancies in standard hypotheses. *)
  Hypothesis Hmain_linkability  : linkable_mains p  c.
  Hypothesis Hmain_linkability' : linkable_mains p' c'.

  Hypothesis Hprog_is_closed  : closed_program (program_link p  c ).
  Hypothesis Hprog_is_closed' : closed_program (program_link p' c').

  Inductive mergeable_states (iface1 iface2 : Program.interface) (s1 s2 : CS.state) : Prop.

  Definition merge_states (s1 s2 : CS.state) : option CS.state :=
    None.

  Theorem initial_states_mergeability s s'' :
    initial_state (CS.sem (program_link p  c )) s   ->
    initial_state (CS.sem (program_link p' c')) s'' ->
    mergeable_states ip ic s s''.
  Admitted.

  Lemma initial_state_merge_after_linking s s'' :
    initial_state (CS.sem (program_link p  c )) s   ->
    initial_state (CS.sem (program_link p' c')) s'' ->
  exists s',
    merge_states s s'' = Some s' /\
    initial_state (CS.sem (program_link p  c')) s'.
  Admitted.

  Theorem threeway_multisem_star_simulation s1 s1'' t s2 s2'' :
    mergeable_states ip ic s1 s1'' ->
    Star (CS.sem (program_link p  c )) s1   t s2   ->
    Star (CS.sem (program_link p' c')) s1'' t s2'' ->
  exists s1' s2',
    merge_states s1 s1'' = Some s1' /\
    merge_states s2 s2'' = Some s2' /\
    Star (CS.sem (program_link p  c')) s1' t s2'.
    (* /\ mergeable_states ip ic s2 s2'' *)
  Admitted.

  Theorem recombination_prefix m :
    does_prefix (CS.sem (program_link p  c )) m ->
    does_prefix (CS.sem (program_link p' c')) m ->
    does_prefix (CS.sem (program_link p  c')) m.
  Admitted.
End Recombination.