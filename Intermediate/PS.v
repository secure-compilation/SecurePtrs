Require Import Common.Definitions.
Require Import Common.Util.
Require Import Common.Memory.
Require Import Common.Linking.
Require Import Common.CompCertExtensions.
Require Import CompCert.Events.
Require Import CompCert.Smallstep.
Require Import Intermediate.Machine.
Require Import Intermediate.GlobalEnv.
Require Import Intermediate.CS.

Require Import Coq.Program.Equality.

From mathcomp Require Import ssreflect ssrfun ssrbool.

Set Implicit Arguments.
Unset Strict Implicit.
Unset Printing Implicit Defensive.

Set Bullet Behavior "Strict Subproofs".

Module PS.

Import Intermediate.

Module PartialPointer.
  Definition t : Type := Component.id * option (Block.id * Block.offset).
End PartialPointer.

Lemma partial_pointer_to_pointer_eq :
  forall pt1 pt2,
    (Pointer.component pt1, Some (Pointer.block pt1, Pointer.offset pt1)) =
    (Pointer.component pt2, Some (Pointer.block pt2, Pointer.offset pt2)) ->
    pt1 = pt2.
Proof. by move=> [[??]?] [[??]?] [-> -> ->]. Qed.

Definition stack := list PartialPointer.t.

Definition program_state : Type := stack * Memory.t * Register.t * Pointer.t.
Definition context_state : Type := Component.id * stack * Memory.t.

Inductive state : Type :=
| PC : program_state -> state
| CC : context_state -> state.

Definition state_component (ps: state) : Component.id :=
  match ps with
  | PC (_, _, _, pc) => Pointer.component pc
  | CC (C, _, _) => C
  end.

Definition state_memory (ps: state) : Memory.t :=
  match ps with
  | PC (_, mem, _, _) => mem
  | CC (_, _, mem) => mem
  end.

Definition state_stack (ps: state) : stack :=
  match ps with
  | PC (gps, _, _, _) => gps
  | CC (_, gps, _) => gps
  end.

Ltac unfold_state st :=
  match goal with
    |- _ => let pgps := fresh "pgps" in
            let pmem := fresh "pmem" in
            let regs := fresh "regs" in
            let pc := fresh "pc" in
            let comp := fresh "C" in
            destruct st as [[[[pgps pmem] regs] pc] | [[comp pgps] pmem]]
  end.

Ltac unfold_states :=
  repeat (match goal with
          | st: state |- _ => unfold_state st
          end).

Instance state_turn : HasTurn state := {
  turn_of s iface :=
    match s with
    | PC (_, _, _, pc) => Pointer.component pc \in domm iface
    | CC (C, _, _) => C \in domm iface
    end
}.

Definition is_context_component (ps: state) ctx := turn_of ps ctx.
Definition is_program_component (ps: state) ctx := negb (is_context_component ps ctx).

Ltac simplify_turn :=
  unfold PS.is_program_component, PS.is_context_component in *;
  unfold turn_of, PS.state_turn in *;
  simpl in *.

Remark pc_component_not_in_ctx:
  forall stk mem regs pc ctx,
    is_program_component (PC (stk, mem, regs, pc)) ctx ->
    Pointer.component pc \notin domm ctx.
Proof.
  intros stk mem regs pc ctx Hpc.
  simplify_turn.
  assumption.
Qed.

Remark cc_component_in_ctx:
  forall cid stk mem ctx,
    is_context_component (CC (cid, stk, mem)) ctx ->
    cid \in domm ctx.
Proof.
  intros cid stk mem ctx Hcc.
  simplify_turn.
  assumption.
Qed.

(* stack partialization *)

Definition to_partial_frame (ctx: {fset Component.id}) frame : PartialPointer.t :=
  if Pointer.component frame \in ctx then
    (Pointer.component frame, None)
  else
    (Pointer.component frame, Some (Pointer.block frame, Pointer.offset frame)).

Definition to_partial_stack (s : CS.stack) (ctx: {fset Component.id}) :=
  map (to_partial_frame ctx) s.

Lemma ptr_within_partial_frame_1 (ctx: Program.interface):
  forall ptr,
    Pointer.component ptr \in domm ctx = true ->
    to_partial_frame (domm ctx) ptr = (Pointer.component ptr, None).
Proof.
  intros ptr Hin_ctx.
  unfold to_partial_frame, Pointer.inc, Pointer.add.
  destruct ptr as [[C b] o]. simpl in *.
  rewrite Hin_ctx. reflexivity.
Qed.

Lemma ptr_within_partial_frame_2 (ctx: Program.interface):
  forall ptr,
    Pointer.component ptr \in domm ctx = false ->
    to_partial_frame (domm ctx) ptr
    = (Pointer.component ptr, Some (Pointer.block ptr, Pointer.offset ptr)).
Proof.
  intros ptr Hnot_in_ctx.
  unfold to_partial_frame, Pointer.inc, Pointer.add.
  destruct ptr as [[C b] o]. simpl in *.
  rewrite Hnot_in_ctx. reflexivity.
Qed.

Lemma to_partial_frame_with_empty_context:
  forall C b o,
    to_partial_frame fset0 (C, b, o) = (C, Some (b, o)).
Proof.
  intros. reflexivity.
Qed.

Lemma to_partial_stack_with_empty_context:
  forall gps1 gps2,
    to_partial_stack gps1 fset0 = to_partial_stack gps2 fset0 ->
    gps1 = gps2.
Proof.
  intros.
  generalize dependent gps2.
  induction gps1.
  - destruct gps2.
    + reflexivity.
    + discriminate.
  - intros.
    induction gps2.
    + discriminate.
    + simpl in *.
      inversion H; subst.
      destruct a as [[]]. destruct a0 as [[]].
      simpl in *. subst.
      rewrite (IHgps1 gps2); auto.
Qed.

(* Memory partialization, *)

(* RB: TODO: Here and above, Program.interface vs. fset. *)
Definition to_partial_memory (mem : Memory.t) (ctx : {fset Component.id}) :=
  filterm (fun k _ => negb (k \in ctx)) mem.

Inductive partial_state (ctx: Program.interface) : CS.state -> PS.state -> Prop :=
| ProgramControl: forall gps pgps mem pmem regs pc,
    (* program has control *)
    is_program_component (PC (pgps, pmem, regs, pc)) ctx ->

    (* we forget about context memories *)
    pmem = to_partial_memory mem (domm ctx) ->

    (* we put holes in place of context information in the stack *)
    pgps = to_partial_stack gps (domm ctx) ->

    partial_state ctx (gps, mem, regs, pc) (PC (pgps, pmem, regs, pc))

| ContextControl: forall gps pgps mem pmem regs pc,
    (* context has control *)
    is_context_component (CC (Pointer.component pc, pgps, pmem)) ctx ->

    (* we forget about context memories *)
    pmem = to_partial_memory mem (domm ctx) ->

    (* we put holes in place of context information in the stack *)
    pgps = to_partial_stack gps (domm ctx) ->

    partial_state ctx (gps, mem, regs, pc) (CC (Pointer.component pc, pgps, pmem)).

Definition partialize (ics: CS.state) (ctx: Program.interface) : PS.state :=
  let '(gps, mem, regs, pc) := ics in
  if Pointer.component pc \in domm ctx then
    CC (Pointer.component pc,
        to_partial_stack gps (domm ctx),
        to_partial_memory mem (domm ctx))
  else
    PC (to_partial_stack gps (domm ctx),
        to_partial_memory mem (domm ctx),
        regs, pc).

Lemma partialize_correct:
  forall ics ips ctx,
    partialize ics ctx = ips <-> partial_state ctx ics ips.
Proof.
  intros ics ips ctx.
  split.
  - intros Hpartialize.
    CS.unfold_states. simpl in *.
    destruct (Pointer.component pc \in domm ctx) eqn:Hcontrol;
      rewrite Hcontrol in Hpartialize; rewrite <- Hpartialize.
    + constructor; try reflexivity.
      * PS.simplify_turn. assumption.
    + constructor; try reflexivity.
      * PS.simplify_turn. rewrite Hcontrol. reflexivity.
  - intros Hpartial_state.
    inversion Hpartial_state; subst; PS.simplify_turn.
    + destruct (Pointer.component pc \in domm ctx) eqn:Hcontrol.
      * rewrite Hcontrol in H. discriminate.
      * rewrite Hcontrol.
        reflexivity.
    + rewrite H.
      reflexivity.
Qed.

Lemma partialized_state_is_partial:
  forall ics ctx,
    partial_state ctx ics (partialize ics ctx).
Proof.
  intros ics ctx.
  apply partialize_correct.
  reflexivity.
Qed.

(* unpartializing partial states without holes *)

Definition unpartialize_stack_frame (frame: PartialPointer.t): Pointer.t :=
  match frame with
  | (C, None) =>
    (* bad case that shouldn't happen, just return first state *)
    (C, 1, 0%Z)
  | (C, Some (b, o)) => (C, b, o)
  end.

Definition unpartialize_stack (pgps: stack): CS.stack :=
  map unpartialize_stack_frame pgps.

Definition unpartialize (ips: state): CS.state :=
  match ips with
  | PC (pgps, mem, regs, pc) =>
    (unpartialize_stack pgps, mem, regs, pc)
  | CC _ =>
    (* bad case that shouldn't happen, return bogus state *)
    ([], emptym, emptym, (0, 0, 0%Z))
  end.

Inductive stack_without_holes: stack -> Prop :=
| stack_without_holes_nil:
    stack_without_holes nil
| stack_without_holes_cons: forall pgps C b o,
    stack_without_holes pgps ->
    stack_without_holes ((C, Some (b, o)) :: pgps).

Lemma to_partial_stack_with_empty_context_has_no_holes:
  forall gps,
    stack_without_holes (to_partial_stack gps fset0).
Proof.
  intros gps.
  induction gps.
  - simpl. constructor.
  - simpl.
    destruct a. destruct p.
    rewrite to_partial_frame_with_empty_context.
    econstructor; auto.
Qed.

Lemma to_partial_stack_unpartialize_identity:
  forall pgps,
    stack_without_holes pgps ->
    to_partial_stack (unpartialize_stack pgps) fset0 = pgps.
Proof.
  intros pgps Hnoholes.
  induction Hnoholes; subst.
  - reflexivity.
  - simpl. rewrite IHHnoholes. reflexivity.
Qed.

Lemma unpartializing_complete_stack_frame:
  forall frame,
    unpartialize_stack_frame (to_partial_frame fset0 frame) = frame.
Proof.
  intros frame.
  destruct frame as [[C b] o].
  reflexivity.
Qed.

Lemma unpartializing_complete_stack:
  forall stack,
    unpartialize_stack (to_partial_stack stack fset0) = stack.
Proof.
  intros stack.
  induction stack; simpl.
  - reflexivity.
  - rewrite IHstack.
    destruct a as [[]].
    reflexivity.
Qed.

Theorem unpartializing_complete_states:
  forall ics,
    unpartialize (partialize ics emptym) = ics.
Proof.
  intros ics.
  CS.unfold_states. simpl.
  rewrite mem_domm. simpl.
  rewrite domm0.
  rewrite unpartializing_complete_stack.
  unfold to_partial_memory. rewrite filterm_identity. reflexivity.
Qed.

(* merging partial states *)

Inductive mergeable_stack_frames: PartialPointer.t -> PartialPointer.t -> Prop :=
| mergeable_stack_frames_first: forall C b1 o1,
    mergeable_stack_frames (C, Some (b1, o1)) (C, None)
| mergeable_stack_frames_second: forall C b2 o2,
    mergeable_stack_frames (C, None) (C, Some (b2, o2)).

Inductive mergeable_stacks : stack -> stack -> Prop :=
| mergeable_stacks_nil:
    mergeable_stacks [] []
| mergeable_stacks_cons: forall pgps1 pgps2 frame1 frame2,
    mergeable_stacks pgps1 pgps2 ->
    mergeable_stack_frames frame1 frame2 ->
    mergeable_stacks (frame1 :: pgps1) (frame2 :: pgps2).

(* RB: TODO: We may want to either define what it means for each component to
   be mergeable as close as possible to its original definition, or collect
   all these together. The current definition of the top-level proof points to
   interface mergeability at least not belonging here, but in the Common part
   of the development. (Is it possible to reorganize the components of the top-
   level proof, in particular the proof of composition where an assumption of
   this type appears, so that this detail is hidden?) *)

Definition mergeable_memories (mem1 mem2: Memory.t): Prop :=
  fdisjoint (domm mem1) (domm mem2).

(* NOTE: Instance of a more general property which may be added to CoqUtils.
   TODO: Harmonize naming of two directions or unify with iff.
         Reduce amount of lemmas, possibly supplement with tactics. *)
Lemma domm_partition :
  forall ctx1 ctx2,
    mergeable_interfaces ctx1 ctx2 ->
  forall gps mem regs pc,
    CS.comes_from_initial_state (gps, mem, regs, pc) (unionm ctx1 ctx2) ->
    Pointer.component pc \notin domm ctx2 ->
    Pointer.component pc \in domm ctx1.
Proof.
  intros ctx1 ctx2 Hmerge gps mem regs pc
         [p [mainP [ics [t [Hwf [Hmain [Hiface [Hini HStar]]]]]]]].
  revert ctx1 ctx2 Hmerge Hiface Hini.
  simpl in HStar.
  remember CS.step as step.
  remember (prepare_global_env p) as env.
  remember (gps, mem, regs, pc) as ics'.
  revert Heqstep p mainP Hwf Hmain Heqenv gps mem regs pc Heqics'.
  apply star_iff_starR in HStar.
  induction HStar as [| s1 t1 s2 t2 s3 t12 HstarR IHHStar Hstep Ht12];
    intros Heqstep p mainP Hwf Hmain Heqenv gps mem regs pc Heqics'
           ctx1 ctx2 Hmerge Hiface Hini Hpc2;
    subst.
  - unfold CS.initial_state, CS.initial_machine_state in Hini.
    rewrite Hmain in Hini.
    destruct (prepare_procedures p (prepare_initial_memory p))
      as [[mem_p dummy] entrypoints_p] eqn:Hprocs.
    inversion Hini; subst; simpl in *.
    inversion Hwf as [_ _ _ _ _ Hmain_existence _].
    specialize (Hmain_existence _ Hmain).
    destruct Hmain_existence as [main_procs [Hmain_procs Hdomm_main_procs]].
    (* TODO: Here is the recurring dommP inelegance again. *)
    assert (Hdomm_procs : Component.main \in domm (prog_procedures p))
      by (apply /dommP; eauto).
    inversion Hwf as [_ Hdef_procs _ _ _ _ _].
    rewrite <- Hdef_procs, Hiface in Hdomm_procs.
    assert (exists CI, (unionm ctx1 ctx2) Component.main = Some CI)
      as [CI Hctx12]
      by (apply /dommP; assumption).
    assert (Hctx2 : ctx2 Component.main = None)
      by (apply /dommPn; assumption).
    rewrite unionmE in Hctx12.
    destruct (ctx1 Component.main) as [main1 |] eqn:Hcase1;
      rewrite Hcase1 in Hctx12;
      simpl in Hctx12.
    + apply /dommP. now eauto.
    + congruence.
  - (* Peel trivial layers off IH. *)
    destruct s2 as [[[gps2 mem2] regs2] pc2].
    specialize (IHHStar (eq_refl _) _ _ Hwf Hmain (eq_refl _)
               gps2 mem2 regs2 pc2 (eq_refl _) ctx1 ctx2 Hmerge Hiface Hini).
    (* Continue by case analysis. *)
    inversion Hstep; subst;
      (* Most cases are straightforward. *)
      try (rewrite Pointer.inc_preserves_component;
           rewrite Pointer.inc_preserves_component in Hpc2;
           auto).
    (* The interesting cases involve tests, jumps, calls and returns. *)
    + match goal with
      | H : find_label_in_component _ pc2 _ = Some _ |- _ =>
        apply find_label_in_component_1 in H;
        rewrite <- H;
        rewrite <- H in Hpc2;
        now auto
      end.
    + match goal with
      | H : Pointer.component pc = Pointer.component pc2 |- _ =>
        rewrite H;
        rewrite H in Hpc2;
        now auto
      end.
    + match goal with
      | H : find_label_in_procedure _ pc2 _ = Some _ |- _ =>
        apply find_label_in_procedure_1 in H;
        rewrite <- H;
        rewrite <- H in Hpc2;
        now auto
      end.
    + (* Calls are well-formed events, so their components are properly imported.
         Because the global interface is closed, this implies they are exported
         at the right place, from which they can be concluded be part of said
         global interface, on one side or the other. *)
      simpl in *.
      match goal with
      | H1 : starR CS.step _ _ ?T1 _, H2 : CS.step _ _ ?T2 _ |- _ =>
        pose proof starR_step H1 H2 (eq_refl _) as Htrace
      end.
      apply star_iff_starR in Htrace.
      pose proof CS.intermediate_well_formed_trace _ _ _ _ _ Htrace Hini Hmain Hwf as Hwft.
      (* We need to play with sequences here; let's get the interesting part
         right first, but not the information is in Hwft. *)
      assert (Hwfe : Traces.well_formed_event (prog_interface p)
                                              (ECall (Pointer.component pc2) P call_arg C')).
      {
        unfold Traces.well_formed_trace in Hwft.
        apply andb_prop in Hwft. destruct Hwft as [_ Hall].
        rewrite seq.all_cat in Hall.
        apply andb_prop in Hall. destruct Hall as [_ Hall].
        rewrite seq.all_seq1 in Hall.
        assumption.
      }
      apply andb_prop in Hwfe. destruct Hwfe as [_ Himported].
      apply imported_procedure_iff in Himported.
      inversion Hmerge as [_ Hclosed_exported].
      rewrite <- Hiface in Hclosed_exported.
      specialize (Hclosed_exported _ _ _ Himported).
      destruct Hclosed_exported as [CI [Hhas_comp Hexporting]].
      apply has_component_in_domm_prog_interface in Hhas_comp.
      (* TODO: Apply dommP on premises less haphazardly. *)
      assert (exists CI', (prog_interface p) C' = Some CI')
        as [CI' HCI']
        by (by apply /dommP).
      rewrite Hiface unionmE in HCI'.
      destruct (ctx1 C') as [CI'' |] eqn:Hcase.
      * apply /dommP. now eauto.
      * rewrite Hcase in HCI'. simpl in HCI'.
        (* TODO: Same artifact on dommP as above. *)
        assert (Hcontra : C' \in domm ctx2) by (apply /dommP; eauto).
        rewrite Hcontra in Hpc2.
        discriminate.
      (* Returns are well-bracketed events, each paired with a prior matching
         call event. The call for the return is itself a well-formed event whose
         source component correctly imports the requisite components. From this
         fact we can case analyze the side of the interface the source is in. *)
    + (* NOTE: Comment above breaks COQDEP build if placed here in this file! *)
      match goal with
      | H1 : starR CS.step _ _ ?T1 _, H2 : CS.step _ _ ?T2 _ |- _ =>
        pose proof starR_step H1 H2 (eq_refl _) as Htrace
      end.
      apply star_iff_starR in Htrace.
      apply CS.intermediate_well_bracketed_trace in Htrace.
      rewrite (CS.initial_state_stack_state0 _ _ Hini) in Htrace.
      destruct (Traces.well_bracketed_trace_inv Htrace) as [t1' [Pid [arg [t2 Ht1]]]].
      subst t1.
      assert (Hwfe : Traces.well_formed_event (prog_interface p)
                                              (ECall (Pointer.component pc) Pid arg
                                                     (Pointer.component pc2))).
      {
        apply star_iff_starR in HstarR.
        pose proof CS.intermediate_well_formed_trace _ _ _ _ _ HstarR Hini Hmain Hwf as Hwft.
        unfold Traces.well_formed_trace in Hwft.
        apply andb_prop in Hwft. destruct Hwft as [_ Hall].
        rewrite seq.all_cat in Hall.
        apply andb_prop in Hall. destruct Hall as [_ Hall].
        apply andb_prop in Hall. destruct Hall as [Hwfe _].
        assumption.
      }
      apply andb_prop in Hwfe. destruct Hwfe as [_ Himported].
      apply imported_procedure_iff in Himported.
      destruct Himported as [CI [Hhas_comp _]].
      unfold Program.has_component in Hhas_comp.
      rewrite Hiface unionmE in Hhas_comp.
      destruct (ctx1 (Pointer.component pc)) as [CI' |] eqn:Hcase;
        rewrite Hcase in Hhas_comp;
        simpl in Hhas_comp.
      * apply /dommP. now eauto.
      * assert (Hcontra : ctx2 (Pointer.component pc) = None)
          by (apply /dommPn; assumption).
        (* TODO: Above, better application of dommPn on a premise. *)
        rewrite Hcontra in Hhas_comp. discriminate.
Qed.

Lemma domm_partition_notin :
  forall ctx1 ctx2,
    mergeable_interfaces ctx1 ctx2 ->
  forall C,
    C \in domm ctx2 ->
    C \notin domm ctx1.
Proof.
by move=> ctx1 ctx2 [[_]]; rewrite fdisjointC=> /fdisjointP.
Qed.

(* RB: TODO: Complete assumptions, possibly rephrase in terms of _neither. *)
Lemma domm_partition_in_both ctx1 ctx2 C :
  mergeable_interfaces ctx1 ctx2 ->
  C \in domm ctx1 ->
  C \in domm ctx2 ->
  False.
Proof.
  intros H H0 H1. apply (domm_partition_notin H) in H1.
  now rewrite H0 in H1.
Qed.

Lemma domm_partition_in_neither ctx1 ctx2 :
    mergeable_interfaces ctx1 ctx2 ->
  forall gps mem regs pc,
    CS.comes_from_initial_state (gps, mem, regs, pc) (unionm ctx1 ctx2) ->
    Pointer.component pc \notin domm ctx1 ->
    Pointer.component pc \notin domm ctx2 ->
    False.
Proof.
  intros Hmerge_ifaces gps mem regs pc Hcomes_from Hnotin1 Hnotin2.
  apply (domm_partition Hmerge_ifaces Hcomes_from) in Hnotin2.
  now rewrite Hnotin2 in Hnotin1.
Qed.

(* RB: TODO: Complete assumptions as above.
   Look for places where instances of this lemma are inlined in the proofs? *)
Lemma domm_partition_in_notin (ctx1 : Program.interface) C :
  C \in domm ctx1 ->
  C \notin domm ctx1 ->
  False.
Proof.
  intros Hin Hnotin. now rewrite Hin in Hnotin.
Qed.

Inductive mergeable_states (ctx1 ctx2: Program.interface): state -> state -> Prop :=
| mergeable_states_intro: forall ics ips1 ips2,
    mergeable_interfaces ctx1 ctx2 ->
    CS.comes_from_initial_state ics (unionm ctx1 ctx2) ->
    partial_state ctx1 ics ips1 ->
    partial_state ctx2 ics ips2 ->
    mergeable_states ctx1 ctx2 ips1 ips2.

Lemma mergeable_stack_frames_sym:
  forall frame1 frame2,
    mergeable_stack_frames frame1 frame2 ->
    mergeable_stack_frames frame2 frame1.
Proof.
  intros.
  inversion H; subst;
    econstructor; auto.
Qed.

Lemma mergeable_stacks_sym:
  forall pgps1 pgps2,
    mergeable_stacks pgps1 pgps2 ->
    mergeable_stacks pgps2 pgps1.
Proof.
  intros pgps1 pgps2 Hmergeable.
  induction Hmergeable; subst;
    constructor; auto.
  - apply mergeable_stack_frames_sym; auto.
Qed.

Lemma mergeable_stacks_partition gps ctx1 ctx2:
    mergeable_interfaces ctx1 ctx2 ->
  forall mem regs pc,
    CS.comes_from_initial_state (gps, mem, regs, pc) (unionm ctx1 ctx2) ->
    mergeable_stacks (to_partial_stack gps (domm ctx1)) (to_partial_stack gps (domm ctx2)).
Proof.
  intros Hmerge mem regs pc
         [p [mainP [ics [t [Hwf [Hmain [Hiface [Hini HStar]]]]]]]].
  revert ctx1 ctx2 Hmerge Hiface Hini.
  simpl in HStar.
  remember CS.step as step.
  remember (prepare_global_env p) as env.
  remember (gps, mem, regs, pc) as ics'.
  revert Heqstep p mainP Hwf Hmain Heqenv gps mem regs pc Heqics'.
  apply star_iff_starR in HStar.
  induction HStar as [| s1 t1 s2 t2 s3 t12 HstarR IHHStar Hstep Ht12];
    intros Heqstep p mainP Hwf Hmain Heqenv gps mem regs pc Heqics'
           ctx1 ctx2 Hmerge Hiface Hini;
    subst.
  - unfold CS.initial_state, CS.initial_machine_state in Hini.
    rewrite Hmain in Hini.
    destruct (prepare_procedures p (prepare_initial_memory p))
      as [[mem_p _] entrypoints_p].
    inversion Hini; subst.
    now constructor.
  - destruct s2 as [[[gps2 mem2] regs2] pc2].
    specialize (IHHStar (eq_refl _) _ _ Hwf Hmain (eq_refl _)
                        gps2 mem2 regs2 pc2 (eq_refl _) _ _ Hmerge Hiface Hini).
    inversion Hstep; subst;
      (* In most cases, the stack is unchanged. The goal is exactly the IH. *)
      try assumption.
    + (* ICall case *)
      simpl. constructor.
      * (* On the one hand, we have the base stack in the IH. *)
        assumption.
      * (* On the other, we have the new frame. *)
        simpl.
        (* TODO: This kind of useful results can be expressed easily as lemmas
           in the fashion of existing results, e.g., domm_partition (ideally,
           derive these from the simplest formulation). *)
        assert (Hdomm : Pointer.component pc2 \in domm ctx1 \/
                        Pointer.component pc2 \in domm ctx2).
        {
          destruct (Pointer.component pc2 \in domm ctx1) eqn:Hcase.
          - left. reflexivity.
          - right.
            eapply domm_partition.
            + apply mergeable_interfaces_sym.
              eassumption.
            + rewrite unionmC.
              * apply star_iff_starR in HstarR.
                now repeat (esplit; eauto).
              * inversion Hmerge as [[_ Hdisjoint] _].
                rewrite fdisjointC.
                assumption.
            + rewrite Hcase. reflexivity.
        }
        destruct Hdomm as [Hdomm | Hdomm];
          rewrite <- Pointer.inc_preserves_component in Hdomm.
        (* TODO: The following two cases are symmetric and could be refactored. *)
        -- assert (Hdomm' : Pointer.component (Pointer.inc pc2) \in domm ctx2 = false).
           {
             apply mergeable_interfaces_sym in Hmerge.
             pose proof domm_partition_notin Hmerge Hdomm as Hdomm'.
             (* TODO: There are probably more succinct ways to do this. *)
             destruct (Pointer.component (Pointer.inc pc2) \in domm ctx2) eqn:Hcase.
             - rewrite Hcase in Hdomm'. discriminate.
             - reflexivity.
           }
           rewrite (ptr_within_partial_frame_1 Hdomm).
           rewrite (ptr_within_partial_frame_2 Hdomm').
           now constructor.
        -- assert (Hdomm' : Pointer.component (Pointer.inc pc2) \in domm ctx1 = false).
           {
             pose proof domm_partition_notin Hmerge Hdomm as Hdomm'.
             (* TODO: There are probably more succinct ways to do this. *)
             destruct (Pointer.component (Pointer.inc pc2) \in domm ctx1) eqn:Hcase.
             - rewrite Hcase in Hdomm'. discriminate.
             - reflexivity.
           }
           rewrite (ptr_within_partial_frame_1 Hdomm).
           rewrite (ptr_within_partial_frame_2 Hdomm').
           now constructor.
    + (* IReturn case: the IH contains the desired substack. *)
      inversion IHHStar; subst.
      assumption.
Qed.

Lemma mergeable_memories_sym:
  forall pmem1 pmem2,
    mergeable_memories pmem1 pmem2 ->
    mergeable_memories pmem2 pmem1.
Proof.
  intros pmem1 pmem2 Hmergeable.
  unfold mergeable_memories in *.
  rewrite fdisjointC. auto.
Qed.

(* RB: TODO: Obtain linkability from mergeability. *)
Lemma mergeable_states_sym:
  forall p c s1 s2,
    well_formed_program p ->
    well_formed_program c ->
    linkable (prog_interface p) (prog_interface c) ->
    mergeable_states (prog_interface c) (prog_interface p) s1 s2 ->
    mergeable_states (prog_interface p) (prog_interface c) s2 s1.
Proof.
  intros p c s1 s2 Hp_wf Hc_wf Hlink Hmergeable.
  inversion Hmergeable; subst.
  - econstructor; auto.
    + apply mergeable_interfaces_sym; assumption.
    + apply CS.comes_from_initial_state_mergeable_sym; eassumption.
    + assumption.
    + assumption.
Qed.

(* TODO: Consider potential refactors with other [mergeable_] results
   as the proofs are being built. *)
Lemma mergeable_states_program_to_program ctx1 ctx2 ps1 ps2 :
  mergeable_states ctx1 ctx2 ps1 ps2 ->
  is_program_component ps1 ctx1 ->
  is_program_component ps2 ctx1.
Proof.
  intros Hmergeable Hpc.
  inversion Hmergeable as [ics ? ? Hmergeable_ifaces Hcomes_from Hpartial1 Hpartial2];
    subst.
  inversion Hpartial1 as [? ? ? ? ? ? Hpc1 | ? ? ? ? ? ? Hcc1]; subst;
    inversion Hpartial2 as [? ? ? ? ? ? Hpc2 | ? ? ? ? ? ? Hcc2]; subst.
  - now destruct (domm_partition_in_neither Hmergeable_ifaces Hcomes_from Hpc1 Hpc2).
  - assumption.
  - assumption.
  - now destruct (domm_partition_in_both Hmergeable_ifaces Hcc1 Hcc2).
Qed.

Lemma mergeable_states_program_to_context ctx1 ctx2 ps1 ps2 :
  mergeable_states ctx1 ctx2 ps1 ps2 ->
  is_program_component ps1 ctx1 ->
  is_context_component ps2 ctx2.
Proof.
  intros Hmergeable Hpc.
  inversion Hmergeable as [ics ? ? Hmergeable_ifaces Hcomes_from Hpartial1 Hpartial2];
    subst.
  inversion Hpartial1 as [? ? ? ? ? ? Hpc1 | ? ? ? ? ? ? Hcc1]; subst;
    inversion Hpartial2 as [? ? ? ? ? ? Hpc2 | ? ? ? ? ? ? Hcc2]; subst.
  - now destruct (domm_partition_in_neither Hmergeable_ifaces Hcomes_from Hpc1 Hpc2).
  - assumption.
  - now destruct (domm_partition_in_notin Hcc1 Hpc).
  - now destruct (domm_partition_in_both Hmergeable_ifaces Hcc1 Hcc2).
Qed.

Lemma mergeable_states_context_to_context ctx1 ctx2 ps1 ps2 :
  mergeable_states ctx1 ctx2 ps1 ps2 ->
  is_context_component ps1 ctx1 ->
  is_context_component ps2 ctx1.
Proof.
  intros Hmergeable Hpc.
  inversion Hmergeable as [ics ? ? Hmergeable_ifaces Hcomes_from Hpartial1 Hpartial2];
    subst.
  inversion Hpartial1 as [? ? ? ? ? ? Hpc1 | ? ? ? ? ? ? Hcc1]; subst;
    inversion Hpartial2 as [? ? ? ? ? ? Hpc2 | ? ? ? ? ? ? Hcc2]; subst.
  - now destruct (domm_partition_in_neither Hmergeable_ifaces Hcomes_from Hpc1 Hpc2).
  - assumption.
  - assumption.
  - now destruct (domm_partition_in_both Hmergeable_ifaces Hcc1 Hcc2).
Qed.

Lemma mergeable_states_context_to_program ctx1 ctx2 ps1 ps2 :
  mergeable_states ctx1 ctx2 ps1 ps2 ->
  is_context_component ps1 ctx1 ->
  is_program_component ps2 ctx2.
Proof.
  intros Hmergeable Hpc.
  inversion Hmergeable as [ics ? ? Hmergeable_ifaces Hcomes_from Hpartial1 Hpartial2];
    subst.
  inversion Hpartial1 as [? ? ? ? ? ? Hpc1 | ? ? ? ? ? ? Hcc1]; subst;
    inversion Hpartial2 as [? ? ? ? ? ? Hpc2 | ? ? ? ? ? ? Hcc2]; subst.
  - now destruct (domm_partition_in_neither Hmergeable_ifaces Hcomes_from Hpc1 Hpc2).
  - destruct (domm_partition_in_notin Hpc Hpc1).
  - assumption.
  - now destruct (domm_partition_in_both Hmergeable_ifaces Hcc1 Hcc2).
Qed.

Lemma mergeable_states_stacks ctx1 ctx2 ips1 ips2 gps1 gps2:
  mergeable_states ctx1 ctx2 ips1 ips2 ->
  state_stack ips1 = gps1 ->
  state_stack ips2 = gps2 ->
  mergeable_stacks gps1 gps2.
Proof.
  intros Hmerge Hstk1 Hstk2.
  inversion Hmerge as [ics ? ? Hmerge_ifaces Hprovenance Hpartial1 Hpartial2]; subst.
    inversion Hpartial1; subst;
    inversion Hpartial2; subst;
    eapply mergeable_stacks_partition; eassumption.
Qed.

Definition merge_stack_frames (frames: PartialPointer.t * PartialPointer.t): PartialPointer.t :=
  match frames with
  | ((C, None), (_, None)) =>
    (* bad case that shouldn't happen, just return first frame *)
    (C, None)
  | ((C, None), (_, Some (b, o))) => (C, Some (b, o))
  | ((C, Some (b, o)), (_, None)) => (C, Some (b, o))
  | ((C, Some (b, o)), (_, Some _)) =>
    (* bad case that shouldn't happen, just return first frame *)
    (C, None)
  end.

Definition merge_stacks (gps1 gps2: stack): stack :=
  map merge_stack_frames (combine gps1 gps2).

Lemma merged_stack_has_no_holes:
  forall pgps1 pgps2,
    mergeable_stacks pgps1 pgps2 ->
    stack_without_holes (merge_stacks pgps1 pgps2).
Proof.
  intros pgps1 pgps2 Hmergeable.
  unfold merge_stacks.
  induction Hmergeable; subst; simpl.
  - constructor.
  - destruct frame1 as [C [[b o]|]];
    destruct frame2 as [C' [[b' o']|]];
      try inversion H.
    + constructor; auto.
    + constructor; auto.
Qed.

(* Lemma placeholder: merge_stacks_partition *)
(* Lemma placeholder: merge_stacks_partition_emptym *)

Definition merge_memories (mem1 mem2: Memory.t): Memory.t :=
  unionm mem1 mem2.

(* Lemma placeholder: merge_memories_partition *)

Definition merge_partial_states (ips1 ips2: state) : state :=
  match ips1 with
  | PC (gps1, mem1, regs, pc) =>
    match ips2 with
    | PC _ =>
      (* bad case that shouldn't happen, just return first state *)
      ips1
    | CC (C, gps2, mem2) =>
      PC (merge_stacks gps1 gps2, merge_memories mem1 mem2, regs, pc)
    end
  | CC (C, gps1, mem1) =>
    match ips2 with
    | PC (gps2, mem2, regs, pc) =>
      PC (merge_stacks gps1 gps2, merge_memories mem1 mem2, regs, pc)
    | CC _ =>
      (* bad case that shouldn't happen, just return first state *)
      ips1
    end
  end.

(* transition system *)

Inductive initial_state (p: program) (ctx: Program.interface) : state -> Prop :=
| initial_state_intro: forall p' ics ips,
    prog_interface p' = ctx ->
    well_formed_program p ->
    well_formed_program p' ->
    linkable (prog_interface p) (prog_interface p') ->
    linkable_mains p p' ->
    partial_state ctx ics ips ->
    CS.initial_state (program_link p p') ics ->
    initial_state p ctx ips.

Inductive final_state (p: program) (ctx: Program.interface) : state -> Prop :=
| final_state_program: forall p' ics ips,
    prog_interface p' = ctx ->
    well_formed_program p ->
    well_formed_program p' ->
    linkable (prog_interface p) (prog_interface p') ->
    linkable_mains p p' ->
    ~ turn_of ips ctx ->
    partial_state ctx ics ips ->
    CS.final_state
      (prepare_global_env (program_link p p')) ics ->
    final_state p ctx ips
| final_state_context: forall ips,
    turn_of ips ctx ->
    final_state p ctx ips.

Inductive step (p: program) (ctx: Program.interface)
  : global_env -> state -> trace -> state -> Prop :=
| partial_step:
    forall p' ips t ips' ics ics',
      prog_interface p' = ctx ->
      well_formed_program p ->
      well_formed_program p' ->
      linkable (prog_interface p) (prog_interface p') ->
      linkable_mains p p' ->
      CS.step (prepare_global_env (program_link p p')) ics t ics' ->
      partial_state ctx ics ips ->
      partial_state ctx ics' ips' ->
      step p ctx (prepare_global_env p) ips t ips'.

(* partial semantics *)

Section Semantics.
  Variable p: program.
  Variable ctx: Program.interface.

  Hypothesis valid_program:
    well_formed_program p.

  Hypothesis disjoint_interfaces:
    fdisjoint (domm (prog_interface p)) (domm ctx).

  Hypothesis merged_interface_is_closed:
    closed_interface (unionm (prog_interface p) ctx).

  Definition sem :=
    @Semantics_gen state global_env (step p ctx)
                   (initial_state p ctx)
                   (final_state p ctx) (prepare_global_env p).

  Lemma singleton_traces:
    single_events sem.
  Proof.
    unfold single_events.
    intros s t s' Hstep.
    (* RB: This generates unnecessarily restrictive conditions. *)
    (* inversion Hstep as [? ? ? ? ? ? ? ? ? ? ? HCSstep]; subst. *)
    (* apply CS.singleton_traces in HCSstep. *)
    (* exact HCSstep. *)
    inversion Hstep; simpl;
      match goal with
      | Hcs_step: CS.step _ _ _ _ |- _ =>
        apply CS.singleton_traces in Hcs_step
      end; auto.
  Qed.
End Semantics.

Theorem context_epsilon_step_is_silent:
  forall p ctx G ips ips',
    is_context_component ips ctx ->
    step p ctx G ips E0 ips' ->
    ips' = ips.
Proof.
  intros p ctx G ips ips' Hcc Hstep.
  inversion Hstep; subst.
  match goal with
  | Hpartial1: partial_state _ _ _,
    Hpartial2: partial_state _ _ _ |- _ =>
    inversion Hpartial2; subst; PS.simplify_turn;
    inversion Hpartial1; subst; PS.simplify_turn
  end.
  - rewrite Hcc in H.
    discriminate.
  - rewrite Hcc in H.
    discriminate.
  - (* contra *)
    assert (Pointer.component pc = Pointer.component pc0) as Hsame_comp. {
      inversion H4; subst;
        try (rewrite Pointer.inc_preserves_component; reflexivity);
        try (symmetry; assumption).
      + erewrite find_label_in_component_1; now eauto.
      + erewrite find_label_in_procedure_1; now eauto.
    }
    rewrite <- Hsame_comp in H7.
    rewrite Hcc in H7.
    discriminate.
  - inversion H4; subst;
      try (rewrite Pointer.inc_preserves_component; reflexivity);
      try (symmetry; assumption).
    + rewrite Pointer.inc_preserves_component.
      destruct ptr as [[]].
      unfold to_partial_memory. erewrite context_store_in_partialized_memory; eauto.
      * rewrite Pointer.inc_preserves_component.
        rewrite <- H18. eassumption.
    + erewrite find_label_in_component_1 with (pc:=pc); eauto.
    + rewrite H18. reflexivity.
    + erewrite find_label_in_procedure_1 with (pc:=pc); eauto.
    + rewrite Pointer.inc_preserves_component.
      unfold to_partial_memory. erewrite context_allocation_in_partialized_memory; eauto.
      * rewrite Pointer.inc_preserves_component.
        eassumption.
Qed.

Corollary context_epsilon_star_is_silent:
  forall p ctx G ctx_state ips',
    is_context_component ctx_state ctx ->
    star (step p ctx) G ctx_state E0 ips' ->
    ips' = ctx_state.
Proof.
  intros p ctx G ctx_state ips' Hcc Hstar.
  dependent induction Hstar; subst.
  - reflexivity.
  - symmetry in H0. apply Eapp_E0_inv in H0. destruct H0. subst.
    apply (context_epsilon_step_is_silent Hcc) in H. subst.
    apply IHHstar; auto.
Qed.

(* Taking care for now not to mangle hypotheses that may be useful later.
   Using the above remarks instead of simplify_turn directly is somewhat faster. *)
Ltac discharge_pc_cc Hpc Hcc :=
  pose proof pc_component_not_in_ctx Hpc as Hin;
  pose proof cc_component_in_ctx Hcc as Hnotin;
  rewrite Pointer.inc_preserves_component in Hnotin;
  rewrite Hnotin in Hin;
  discriminate.

(* Early renaming of hypotheses generated by cumbersome step inversions.
   Useful for later quick selection of hypotheses without pattern matching. *)
Ltac rename_op p pc1 P12 HOP :=
  match goal with
  | Hop : executing (prepare_global_env (program_link p P12)) pc1 _ |- _ =>
    rename Hop into HOP
  end.

(* In the program, both steps in sync should fetch the same instruction.
   By chaining inversions on component procedures, procedure code and
   instruction, goals involving pairs of non-matching instructions are
   moreover discharged by contradiction. *)
Ltac unify_op Hop1 Hop2 Hcomp Hwf Hwf1 Hwf2 Hlink1 Hlink2 Hmains1 Hmains2 Hsame_iface :=
  apply pc_component_not_in_ctx in Hcomp;
  pose proof Hcomp as Hcomp';
  rewrite <- Hsame_iface in Hcomp';
  inversion Hop1 as [procs1 [code1 [Hgenv1 [Hprocs1 [_ Hinstr1]]]]];
  inversion Hop2 as [procs2 [code2 [Hgenv2 [Hprocs2 [_ Hinstr2]]]]];
  pose proof @genv_procedures_program_link_left_notin _ _ Hcomp _ Hwf Hwf1 Hlink1 Hmains1
    as Hgenv1';
  pose proof @genv_procedures_program_link_left_notin _ _ Hcomp' _ Hwf Hwf2 Hlink2 Hmains2
    as Hgenv2';
  rewrite Hgenv1' in Hgenv1;
  rewrite Hgenv2' in Hgenv2;
  rewrite Hgenv2 in Hgenv1;
  inversion Hgenv1; subst procs2;
  rewrite Hprocs2 in Hprocs1;
  inversion Hprocs1; subst code2;
  rewrite Hinstr2 in Hinstr1;
  inversion Hinstr1.

Ltac discharge_op_neq Hop1 Hop2 Hcomp Hwf Hwf1 Hwf2 Hlink1 Hlink2 Hmains1 Hmains2 Hsame_iface :=
  unify_op Hop1 Hop2 Hcomp Hwf Hwf1 Hwf2 Hlink1 Hlink2 Hmains1 Hmains2 Hsame_iface;
  discriminate.

Ltac unify_op_eq Hop1 Hop2 Hcomp Hwf Hwf1 Hwf2 Hlink1 Hlink2 Hmains1 Hmains2 Hsame_iface :=
  unify_op Hop1 Hop2 Hcomp Hwf Hwf1 Hwf2 Hlink1 Hlink2 Hmains1 Hmains2 Hsame_iface;
  subst.

Ltac unify_get :=
  match goal with
  | Hget1 : Register.get ?REG ?REGS = ?V1,
    Hget2 : Register.get ?REG ?REGS = ?V2 |- _ =>
    rewrite Hget2 in Hget1;
    inversion Hget1; subst
  end.

Ltac unify_load pc Hcomp Hmem12 :=
  match goal with
  | Hload1 : Memory.load ?CMEM1 ?PTR = Some ?V1,
    Hload2 : Memory.load ?CMEM2 ?PTR = Some ?V2,
    Heq: Pointer.component ?PTR = Pointer.component pc |- _ =>
    pose proof Hcomp as Hptr;
    rewrite <- Heq in Hptr;
    pose proof program_load_in_partialized_memory Hmem12 Hptr Hload1 Hload2;
    subst
  end.

Ltac unify_store pc Hcomp Hmem12 :=
  match goal with
  | Hstore1 : Memory.store ?CMEM1 ?PTR ?GET = Some ?MEM1,
    Hstore2 : Memory.store ?CMEM2 ?PTR ?GET = Some ?MEM2,
    Heq: Pointer.component ?PTR = Pointer.component pc |- _ =>
    pose proof Hcomp as Hptr;
    rewrite <- Heq in Hptr;
    pose proof program_store_in_partialized_memory Hmem12 Hptr Hstore1 Hstore2 as Hmem12';
    rewrite Hmem12'
  end.

Ltac unify_component_label Hcomp Hcomp' Hwf Hwf1 Hwf2 Hlink1 Hlink2 Hmains1 Hmains2 :=
  match goal with
  | Hlabel1 : find_label_in_component (prepare_global_env (program_link ?P ?P1)) ?PC ?L = Some ?PC1,
    Hlabel2 : find_label_in_component (prepare_global_env (program_link ?P ?P2)) ?PC ?L = Some ?PC2  |- _ =>
    pose proof @find_label_in_component_program_link_left _ _ Hcomp _ Hwf Hwf1 Hlink1 Hmains1
      as Hlabel1';
    pose proof @find_label_in_component_program_link_left _ _ Hcomp' _ Hwf Hwf2 Hlink2 Hmains2
      as Hlabel2';
    rewrite Hlabel1' in Hlabel1;
    rewrite Hlabel2' in Hlabel2;
    rewrite Hlabel2 in Hlabel1;
    inversion Hlabel1; subst
  end.

Ltac unify_procedure_label Hcomp Hcomp' Hwf Hwf1 Hwf2 Hlink1 Hlink2 Hmains1 Hmains2 :=
  match goal with
  | Hlabel1 : find_label_in_procedure (prepare_global_env (program_link ?P ?P1)) ?PC ?L = Some ?PC1,
    Hlabel2 : find_label_in_procedure (prepare_global_env (program_link ?P ?P2)) ?PC ?L = Some ?PC2  |- _ =>
    pose proof @find_label_in_procedure_program_link_left _ _ Hcomp _ Hwf Hwf1 Hlink1 Hmains1
      as Hlabel1';
    pose proof @find_label_in_procedure_program_link_left _ _ Hcomp' _ Hwf Hwf2 Hlink2 Hmains2
      as Hlabel2';
    rewrite Hlabel1' in Hlabel1;
    rewrite Hlabel2' in Hlabel2;
    rewrite Hlabel2 in Hlabel1;
    inversion Hlabel1; subst
  end.

(* RB: TODO: Simplify Some pattern. *)
Ltac unify_alloc Hmem12 Hcomp :=
  match goal with
  | Halloc1 : Memory.alloc ?CMEM1 ?CID ?SIZE = Some (?MEM1, ?PTR1),
    Halloc2 : Memory.alloc ?CMEM2 ?CID ?SIZE = Some (?MEM2, ?PTR2) |- _ =>
    pose proof program_allocation_in_partialized_memory Hmem12 Hcomp Halloc1 Halloc2
      as [Hptr Halloc];
    subst;
    rewrite Halloc
  end.

(* At the moment, with the new definitions, two pattern-maching scenarios
      EntryPoint.get ?C ?PROC (_ (program_link ?P ?P1))
      EntryPoint.get ?C ?PROC (_ (_ (program_link ?P ?P1)))
   depending on the state of unfolding. Ltac is not smart enough to see one
   as a special case of the other. It is innocuous at the moment and quick
   to ignore that part of the pattern-match, but even wildcards in place of
   the concrete, now duplicate pattern, are less clear. *)
Ltac unify_entrypoint Hpc1' Hpc2' Hwf Hwf1 Hwf2 Hlink1 Hlink2 Hmains1 Hmains2 Hsame_iface :=
  match goal with
  | Hentry1 : EntryPoint.get ?C ?PROC _ = ?B1,
    Hentry2 : EntryPoint.get ?C ?PROC _ = ?B2  |- _ =>
    pose proof @genv_entrypoints_program_link_left _ _ Hpc1' _ Hwf Hwf1 Hlink1 Hmains1
      as Hentry1';
    rewrite <- Hsame_iface in Hpc2';
    pose proof @genv_entrypoints_program_link_left _ _ Hpc2' _ Hwf Hwf2 Hlink2 Hmains2
      as Hentry2';
    rewrite Hentry1' in Hentry1;
    rewrite Hentry2' in Hentry2;
    rewrite Hentry2 in Hentry1;
    inversion Hentry1; subst
  end.

Ltac unify_inc_pc Hcc1 Hcc2 :=
  rewrite <- Pointer.inc_preserves_component in Hcc1;
  rewrite (ptr_within_partial_frame_1 Hcc1);
  rewrite Pointer.inc_preserves_component;
  rewrite <- Pointer.inc_preserves_component in Hcc2;
  rewrite (ptr_within_partial_frame_1 Hcc2);
  rewrite Pointer.inc_preserves_component.

Ltac unify_regs :=
  match goal with
  | Hregs1 : Register.get R_COM ?REGS1 = Int ?CALL_ARG,
    Hregs2 : Register.get R_COM ?REGS2 = Int ?CALL_ARG |- _ =>
    rewrite <- Hregs1 in Hregs2;
    rewrite (Register.invalidate_eq Hregs2)
  end.

Ltac unify_components_eq :=
  match goal with
  | Hcomps : Pointer.component ?PC1 = Pointer.component ?PC2 |- _ =>
    rewrite Hcomps
  end.

(* Turns must have been simplified. *)
Ltac discharge_pc Hpc Hcc :=
  rewrite Hcc in Hpc;
  discriminate.

(* Generates two sub-goals. *)
Ltac analyze_stack p1 pc1 pc2 Hhead :=
  match goal with
  | Heq : Pointer.component pc1 = Pointer.component pc2  |- _ =>
    unfold to_partial_frame in Hhead;
    (* Case analysis on both frame pointers. *)
    destruct (Pointer.component pc1 \in domm (prog_interface p1)) eqn:Heq1;
    destruct (Pointer.component pc2 \in domm (prog_interface p1)) eqn:Heq2;
    [                                               (* User-guided contradiction *)
    | discriminate                                  (* Direct contradiction *)
    | discriminate                                  (* Direct contradiction *)
    | apply partial_pointer_to_pointer_eq in Hhead;
      subst                                         (* User tactic *)
    ]
  end.

(* RB: Where to put this? Is it direct from CoqUtils?
   As it is, just a convenience to make tactics more readable. *)
Remark notin_to_in_false : forall (Cid : Component.id) (iface : Program.interface),
  Cid \notin domm iface -> Cid \in domm iface = false.
Proof.
  intros Cid iface Hnotin.
  destruct (Cid \in domm iface) eqn:Heq;
    easy.
Qed.

(* we can prove a strong form of state determinism when the program is in control *)
Lemma state_determinism_program' p ctx G sps t1 t2 sps' :
  is_program_component sps ctx ->
  step p ctx G sps t1 sps' ->
  forall sps'', step p ctx G sps t2 sps'' ->
                t1 = t2 /\ sps' = sps''.
Admitted. (* Grade 3. Not hard; requires some additional porting from Source. *)

Lemma state_determinism_program:
  forall p ctx G ips t ips',
    is_program_component ips ctx ->
    step p ctx G ips t ips' ->
  forall ips'',
    step p ctx G ips t ips'' ->
    ips' = ips''.
Proof.
  intros p ctx G ps t ps1 Hcomp Hstep_ps1 ps2 Hstep_ps2.

  inversion Hstep_ps1
    as [p1 ? ? ? cs1 cs1' ? Hwfp Hwfp1 Hlink1 Hmains1 Hstep_cs1 Hpartial1 Hpartial1'];
    subst.
  inversion Hstep_ps2
    as [p2 ? ? ? cs2 cs2' Hsame_iface _ Hwfp2 Hlink2 Hmains2 Hstep_cs2 Hpartial2 Hpartial2'];
    subst.

  (* Case analysis on who has control. *)
  inversion Hpartial1 as [cstk1 ? cmem1 ? regs1 pc1 Hpc1 | cstk1 ? cmem1 ? regs1 pc1 Hcc1];
    subst;
    (* Context control is discharged by contradiction. *)
    last (simplify_turn; rewrite Hcc1 in Hcomp; discriminate).

  inversion Hpartial2 as [cstk2 ? cmem2 ? regs2 pc2 Hpc2 Hmem12 Hstk12 |]; subst.
  (* First, case analysis of CS steps with explicit naming of hypotheses of interest.
     Cases where the operations in both steps do not coincide can be discharged. *)
  inversion Hstep_cs1; subst; rename_op p pc1 p1 Hop1;
    inversion Hstep_cs2; subst; rename_op p pc1 p2 Hop2;
    try discharge_op_neq Hop1 Hop2 Hcomp Hwfp Hwfp1 Hwfp2 Hlink1 Hlink2 Hmains1 Hmains2 Hsame_iface;
    (* Second, case analysis of partial steps.
       Cases where program and component do not match can be discharged. *)
    inversion Hpartial1'
      as [cstk1' ? cmem1' ? regs1' pc1' Hpc1' | cstk1' ? cmem1' ? regs1' pc1' Hcc1'];
      subst;
    inversion Hpartial2'
      as [cstk2' ? cmem2' ? regs2' pc2' Hpc2' | cstk2' ? cmem2' ? regs2' pc2' Hcc2'];
      subst;
    (* (Now that we are done inverting, expose this definition.) *)
    unfold to_partial_memory in *;
    try discharge_pc_cc Hcomp Hcc1';
    try discharge_pc_cc Hcomp Hcc2';
    (* For the remaining goals, unify components of their matching opcodes and their
       various optional components: register and memory reads and stores, component
       labels, allocs and entry points. *)
    unify_op_eq Hop1 Hop2 Hcomp Hwfp Hwfp1 Hwfp2 Hlink1 Hlink2 Hmains1 Hmains2 Hsame_iface;
    simplify_turn;
    try unify_get;
    try unify_load pc1 Hcomp Hmem12;
    try unify_store pc1 Hcomp Hmem12;
    try unify_component_label Hcomp Hcomp' Hwfp Hwfp1 Hwfp2 Hlink1 Hlink2 Hmains1 Hmains2;
    try unify_procedure_label Hcomp Hcomp' Hwfp Hwfp1 Hwfp2 Hlink1 Hlink2 Hmains1 Hmains2;
    try unify_alloc Hmem12 Hcomp;
    try unify_entrypoint Hpc1' Hpc2' Hwfp Hwfp1 Hwfp2 Hlink1 Hlink2 Hmains1 Hmains2 Hsame_iface;
    (* Rewrite memory and stack, where applicable. *)
    try rewrite Hmem12;
    try rewrite Hstk12;
    (* With this, most goals go away either by reflexivity or by contradiction, either
       direct or on the turns of both components. *)
    try reflexivity;
    try contradiction;
    try discharge_pc Hpc1' Hcc2';
    try discharge_pc Hpc2' Hcc1';
    (* All that remains are returns, in which case the stack is decomposed. *)
    inversion Hstk12 as [[Hhead Htail]].
  (* RB: TODO: Discharges and proof strategies can be found automatically. *)
  - analyze_stack p1 pc'0 pc' Hhead.
    + discharge_pc Hpc2' Heq1.
    + reflexivity.
  - analyze_stack p1 pc'0 pc' Hhead.
    + discharge_pc Hpc1' Heq2.
    + discharge_pc Hcc2' Heq2.
  - analyze_stack p1 pc'0 pc' Hhead.
    + discharge_pc Hpc2' Heq1.
    + discharge_pc Hcc1' Heq1.
  - congruence.
Qed.

Lemma state_determinism_context:
  forall p ctx G ips t ips',
    is_context_component ips ctx ->
    step p ctx G ips t ips' ->
  forall ips'',
    step p ctx G ips t ips'' ->
    ips' = ips''.
Proof.
  intros p ctx G ps t ps1 Hcomp Hstep_ps1 ps2 Hstep_ps2.

  inversion Hstep_ps1
    as [p1 ? ? ? cs1 cs1' ? Hwfp Hwfp1 Hlink1 Hmains1 Hstep_cs1 Hpartial1 Hpartial1'];
    subst.
  inversion Hstep_ps2
    as [p2 ? ? ? cs2 cs2' Hsame_iface _ Hwfp2 Hlink2 Hmains2 Hstep_cs2 Hpartial2 Hpartial2'];
    subst.

  (* Case analysis on who has control. *)
  inversion Hpartial1 as [cstk1 ? cmem1 ? regs1 pc1 Hpc1 | cstk1 ? cmem1 ? regs1 pc1 Hcc1];
    subst;
    (* Program control is discharged by contradiction. *)
    first (simplify_turn; rewrite Hcomp in Hpc1; discriminate).

  inversion Hpartial2 as [| cstk2 ? cmem2 ? regs2 pc2 Hcc2 Hmem12 Hstk12 DUMMY Hcompeq];
    subst.
  (* First, case analysis of CS steps. *)
  inversion Hstep_cs1; subst;
    inversion Hstep_cs2; subst;
    (* All subgoals but two involve an emtpy trace: state determinism applies. *)
    try (rewrite (context_epsilon_step_is_silent Hcomp Hstep_ps1);
         rewrite (context_epsilon_step_is_silent Hcomp Hstep_ps2);
         reflexivity);
    inversion Hpartial1'
      as [cstk1' ? cmem1' ? regs1' pc1' Hpc1' | cstk1' ? cmem1' ? regs1' pc1' Hcc1'];
      subst;
    inversion Hpartial2'
      as [cstk2' ? cmem2' ? regs2' pc2' Hpc2' | cstk2' ? cmem2' ? regs2' pc2' Hcc2'];
      subst;
    simplify_turn.
  (* ICall *)
  - rewrite Hmem12.
    rewrite Hstk12.
    unify_inc_pc Hcc1 Hcc2.
    unify_regs.
    unify_components_eq.
    unify_entrypoint Hpc1' Hpc2' Hwfp Hwfp1 Hwfp2 Hlink1 Hlink2 Hmains1 Hmains2 Hsame_iface.
    reflexivity.
  - discharge_pc Hpc1' Hcc2'.
  - discharge_pc Hpc2' Hcc1'.
  - rewrite Hmem12.
    rewrite Hstk12.
    unify_inc_pc Hcc1 Hcc2.
    unify_components_eq.
    reflexivity.
  (* IReturn *)
  - rewrite Hmem12.
    inversion Hstk12 as [Hstk12'].
    rewrite (ptr_within_partial_frame_2 (notin_to_in_false Hpc1')) in Hstk12'.
    rewrite (ptr_within_partial_frame_2 (notin_to_in_false Hpc2')) in Hstk12'.
    apply partial_pointer_to_pointer_eq in Hstk12'; subst.
    unify_regs.
    reflexivity.
  - rewrite (ptr_within_partial_frame_1 Hcc2') in Hstk12.
    rewrite (ptr_within_partial_frame_2 (notin_to_in_false Hpc1')) in Hstk12.
    easy.
  - rewrite (ptr_within_partial_frame_1 Hcc1') in Hstk12.
    rewrite (ptr_within_partial_frame_2 (notin_to_in_false Hpc2')) in Hstk12.
    easy.
  - rewrite Hmem12.
    inversion Hstk12.
    unify_components_eq.
    reflexivity.
Qed.

Theorem state_determinism:
  forall p ctx G ips t ips',
    step p ctx G ips t ips' ->
  forall ips'',
    step p ctx G ips t ips'' ->
    ips' = ips''.
Proof.
  intros p ctx G ps t ps1 Hstep_ps1 ps2 Hstep_ps2.
  inversion Hstep_ps1 as [? ? ? ? ? _ _ _ _ _ _ _ Hpartial1 _]; subst.
  (* Case analysis on who has control. *)
  inversion Hpartial1; subst.
  - eapply state_determinism_program; eassumption.
  - eapply state_determinism_context; eassumption.
Qed.

Lemma state_determinism_star_E0 p ctx s s1 s2 :
  star (PS.step p ctx) (prepare_global_env p) s E0 s1 ->
  star (PS.step p ctx) (prepare_global_env p) s E0 s2 ->
  star (PS.step p ctx) (prepare_global_env p) s1 E0 s2 \/
  star (PS.step p ctx) (prepare_global_env p) s2 E0 s1.
Proof.
move=> Hstar1.
elim/star_E0_ind': s s1 / Hstar1 s2=> [s|s s1 s1' Hstep1 Hstar1 IH] s2; eauto.
move=> Hstar2; elim/star_E0_ind': s s2 / Hstar2 Hstep1.
  by move=> s Hstep1; right; apply: star_step; eauto.
move=> s s2 s2' Hstep2 Hstar2 _ Hstep1; apply: IH.
suffices -> : s1 = s2 by [].
by apply: state_determinism Hstep2.
Qed.

Lemma state_determinism_star_same_trace p ctx s t s1 s2 :
  star (PS.step p ctx) (prepare_global_env p) s t s1 ->
  star (PS.step p ctx) (prepare_global_env p) s t s2 ->
  star (PS.step p ctx) (prepare_global_env p) s1 E0 s2 \/
  star (PS.step p ctx) (prepare_global_env p) s2 E0 s1.
Proof.
elim: t s => [|e t IH] s; first exact: state_determinism_star_E0.
case/(star_cons_inv (@singleton_traces p ctx)) => [s' [s1' [e_01 [e_11 e_t1]]]].
case/(star_cons_inv (@singleton_traces p ctx)) => [s'_ [s2' [e_02 [e_12]]]].
have {e_01 e_02} e_s : s' = s'_.
  have {e_t1 IH} H := state_determinism_star_E0 e_01 e_02.
  without loss H : s' s'_ s1' s2' e_11 e_12 {H e_01 e_02} / Star (sem p ctx) s' E0 s'_.
    by case: H; eauto=> H1 H2; apply: esym; eauto.
  have [in_c|in_p] := boolP (is_context_component s' ctx).
    symmetry. (* RB: The equality of the following lemma is reversed! *)
    exact: context_epsilon_star_is_silent in_c H.
  elim/star_E0_ind: s' s'_ / H in_p e_11 {e_12} => //.
  move=> s' s'm s'_ Hstep1 _ in_p Hstep2.
  by have [] := state_determinism_program' in_p Hstep1 Hstep2.
move: e_s e_12 => <- {s'_} e_12.
by have {s2' e_12} <- := state_determinism e_11 e_12; eauto.
Qed.

(* RB: TODO: Port missing generic results from Source.PS to here. *)

Lemma comes_from_initial_state_step_trans :
  forall p ctx ics ips t ics' ips',
    CS.comes_from_initial_state ics (unionm (prog_interface p) ctx) ->
    step p ctx (prepare_global_env p) ips t ips' ->
    ips = partialize ics ctx ->
    ips' = partialize ics' ctx ->
    CS.comes_from_initial_state ics' (unionm (prog_interface p) ctx).
Admitted. (* Grade 3. *)

Lemma initial_state_exists :
  forall p c,
    well_formed_program p ->
    well_formed_program c ->
    linkable (prog_interface p) (prog_interface c) ->
    linkable_mains p c ->
  exists s,
    initial_state p (prog_interface c) s.
Proof.
  eexists. econstructor; try (reflexivity || assumption).
  apply partialized_state_is_partial.
Qed.

Lemma not_initial_state_contra : forall p c,
  well_formed_program p ->
  well_formed_program c ->
  linkable (prog_interface p) (prog_interface c) ->
  linkable_mains p c ->
  (forall s, ~ initial_state p (prog_interface c) s) ->
  False.
Proof.
  intros ? ? H1 H2 H3 H4 Hcontra.
  destruct (initial_state_exists H1 H2 H3 H4) as [s ?].
  specialize (Hcontra s).
  contradiction.
Qed.

(* A version of state determinism inspired by the needs and resources in
   Composition. RB: NOTE: Consider a simpler version of this result such as is
   given for Source.PS. *)
Lemma initial_state_determinism :
  forall p c s1 s2,
    initial_state p (prog_interface c) s1 ->
    initial_state p (prog_interface c) s2 ->
    well_formed_program p ->
    well_formed_program c ->
    closed_program (program_link p c) ->
    linkable (prog_interface p) (prog_interface c) ->
    linkable_mains p c ->
    s1 = s2.
Proof.
  intros p c ? ?
         [c1 ics1 s1 Hiface1 _ Hwf1 Hlinkable1 Hmains1 Hpartial1 HCSini1]
         [c2 ics2 s2 Hiface2 _ Hwf2 Hlinkable2 Hmains2 Hpartial2 HCSini2]
         Hwfp Hwfc Hclosed Hlinkable Hmains.
  unfold CS.initial_state in HCSini1, HCSini2; subst ics1 ics2.
  (* RB: TODO: Possibly spin out another mini-lemma for the application to
     CS.initial_machine_state. *)
  symmetry in Hiface1, Hiface2.
  assert (Hclosed1 : closed_program (program_link p c1)). {
    apply interface_preserves_closedness_r' with (p2 := c); assumption.
  }
  assert (Hclosed2 : closed_program (program_link p c2)). {
    apply interface_preserves_closedness_r' with (p2 := c); assumption.
  }
  rewrite CS.initial_machine_state_after_linking in Hpartial1; try assumption.
  rewrite CS.initial_machine_state_after_linking in Hpartial2; try assumption.
  (* Case analysis on the location of the main procedure, exposing some of the
     structure up front to make case rewrites automatic. Also observe the common
     case analysis and inversion structure on both cases, susceptible to simple,
     tactic-based refactoring (or otherwise). *)
  unfold linkable_mains in Hmains1, Hmains2.
  inversion Hclosed1 as [_ [mainpc1 [main_procs1 [Hmainpc1 _]]]].
  inversion Hclosed2 as [_ [mainpc2 [main_procs2 [Hmainpc2 _]]]].
  simpl in Hmainpc1, Hmainpc2.
  unfold CS.prog_main_block in Hpartial1, Hpartial2.
  destruct (prog_main p) as [mainp |] eqn:Hmainp.
  - (* main in p. *)
    destruct (prog_main c1) as [mainc1 |] eqn:Hmainc1; first discriminate.
    destruct (prog_main c2) as [mainc1 |] eqn:Hmainc2; first discriminate.
    inversion Hpartial1 as [? ? ? ? ? ? Hcomp1 | ? ? ? ? ? ? Hcomp1]; subst;
      inversion Hpartial2 as [? ? ? ? ? ? Hcomp2 | ? ? ? ? ? ? Hcomp2]; subst;
      simplify_turn.
    + admit. (* Easy. *)
    + admit. (* Contra. *)
    + admit. (* Contra. *)
    + admit. (* Contra/easy. *)
  - (* main in c1 and c2. *)
    destruct (prog_main c1) as [mainc1 |] eqn:Hmainc1; last discriminate.
    destruct (prog_main c2) as [mainc2 |] eqn:Hmainc2; last discriminate.
    inversion Hpartial1 as [? ? ? ? ? ? Hcomp1 | ? ? ? ? ? ? Hcomp1]; subst;
      inversion Hpartial2 as [? ? ? ? ? ? Hcomp2 | ? ? ? ? ? ? Hcomp2]; subst;
      simplify_turn.
    + admit. (* Contra. *)
    + admit. (* Contra. *)
    + admit. (* Contra. *)
    + admit. (* Easy. *)
Admitted. (* Grade 1. *)

End PS.
