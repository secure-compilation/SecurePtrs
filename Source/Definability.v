Require Import Lib.Extra.
Require Import CompCert.Events.
Require Import CompCert.Smallstep.
Require Import CompCert.Behaviors.
Require Import Common.Definitions.
Require Import Common.Util.
Require Import Common.Values.
Require Import Common.Memory.
Require Import Common.Linking.
Require Import Common.CompCertExtensions.
Require Import Common.Traces.
Require Import Common.TracesInform.
Require Import Common.RenamingOption.
Require Import Source.Language.
Require Import Source.GlobalEnv.
Require Import Source.CS.
Require Import Source.NoLeak.
Require Import Source.CSInvariants.

Require Import Lia.
Require Intermediate.Machine.
Require Intermediate.CS.
Require Intermediate.CSInvariants.

From Coq Require Import ssreflect ssrfun ssrbool.
From mathcomp Require Import eqtype seq.
From mathcomp Require ssrnat.

Set Implicit Arguments.
Unset Strict Implicit.
Unset Printing Implicit Defensive.

Set Bullet Behavior "Strict Subproofs".

Section Definability.
  Local Open Scope fset_scope.

  Variable intf: Program.interface.
  Variable closed_intf: closed_interface intf.
  Variable has_main: intf Component.main.

  Variable prog_buffers : NMap (nat + list value).
  Hypothesis domm_buffers : domm intf = domm prog_buffers.
  (* Essentially a copy of the intermediate [wfprog_well_formed_buffers]. *)
  Hypothesis wf_buffers :
    forall C buf,
      prog_buffers C = Some buf ->
      Buffer.well_formed_buffer buf.

  (** The definability proof takes an execution trace as its input and builds a
      source program that can produce that trace.  Roughly speaking, it does so
      by keeping one counter for each component, and using that counter to track
      how many calls or returns have been executed by that component.

      To see how this works, suppose that we have an interface with two
      procedures P1 and P2, which live in components C1 and C2.  Given the trace
   *)


  (**   ECall mainC P1    0 C1
        ECall C1    P2    1 C2
        ERet  C2          2 C1
        ECall C1    P2    3 C2
        ECall C2    mainP 4 mainC *)

  (** we would produce the program *)

  (**   C1 {
          P1() {
            if (local[0] == 0) {
              local[0]++;
              C2.P2(1);
              C1.P1(0);
            } else if (local[0] == 1) {
              local[0]++;
              C2.P2(3);
              C1.P1(0);
            } else {
              exit();
            }
          }
        }

        C2 {
          P2() {
            if (local[0] == 0) {
              local[0]++;
              return 2;
            } else if (local[0] == 1) {
              local[0]++;
              mainC.mainP(4);
              C2.P2(0);
            } else {
              exit();
            }
          }
        } *)

  (** TODO: [DynShare] Complete, relocate.

      In the memory sharing case, back-translation will offset whole blocks to
      make room for a certain amount of metadata, as appropriate. The choice of
      shifting whole blocks somewhat complicates the trace relation (and the
      notion of shared address in particular), but it is less disruptive than
      performing shifting inside a block to reserve some space for
      back-translation metadata. The issue is that metadata must never be
      shared, but the block where it is contained may.

      In general, whenever there is dynamic memory sharing, shared addresses
      need to be unobservable. In this setting, the presence of metadata imposes
      a need to hide said metadata.

      In particular, if the granularity of address sharing is offset-based (not
      block-based), it will be difficult to know if the behavior of the receiver
      is influenced by those data.

      However, we do know whether a given component was or not the result of
      back-translation, so we could reserve a given block (say, block 0) for
      metadata, and therefore make it private by construction. In this model,
      the complexity of the back-translated code increases only moderately. The
      idea is that a component may share its local buffer, but never its
      metadata buffer, so the two need to be separate. One way to achieve this
      is as follows:

      When a component is called, it checks whether it is the first time that it
      has been called. If this is the case, it allocates a new local buffer for
      its private metadata, distinct from the "program-local" buffer. This is
      combined with a simple constant shifting scheme in the trace relation.

      A program back-translation is parametric on the interface as well as the
      static buffers of the program being back-translated, given that their
      contents can affect execution in ways unaccounted for in the program
      trace, in particular in the event of sharing of a component's local
      buffer. A back-translated component must therefore initialize its
      "program-local" buffer with the same contents in the original component
      for their behaviors to match.

      TODO Extend/adapt example *)

  (** If a component has multiple procedures, they can share the same
      code. Notice that each branch that performs call performs a recursive call
      at the end.  This is needed to trigger multiple events from a single
      function.

      The first ingredient needed to perform this translation is a switch
      statement that runs code based on the value of the first local variable.

   *)

  (* If the local counter (first position of the local buffer) contains the
     value [n], increment it and execute [e_then], otherwise execute
     [e_else]. *)
  Definition switch_clause (n : Z) (e_then e_else : expr) : expr :=
    let one := E_val (Int 1%Z) in
    E_if (E_binop Eq (E_deref E_local) (E_val (Int n)))
         (E_seq (E_assign E_local (E_binop Add (E_deref E_local) one)) e_then)
         e_else.

  Ltac take_step :=
    match goal with
    | |- @star _ _ _ _ _ _ ?t _ =>
        eapply (@star_step _ _ _ _ _ _ E0 _ t _ t); trivial; [econstructor|]
    end.

  Ltac take_steps := (take_step; [take_steps]) || (take_step; try reflexivity).

  Lemma switch_clause_spec p' P C stk mem n n' e_then e_else arg :
    Memory.load mem (P, C, Block.local, 0%Z) = Some (Int n) ->
    if (n =? n') % Z then
      exists mem',
        Memory.store mem (P, C, Block.local, 0%Z) (Int (Z.succ n)) = Some mem' /\
          Star (CS.sem p')
               [CState C, stk, mem , Kstop, switch_clause n' e_then e_else, arg] E0
               [CState C, stk, mem', Kstop, e_then, arg]
    else
      Star (CS.sem p')
           [CState C, stk, mem, Kstop, switch_clause n' e_then e_else, arg] E0
           [CState C, stk, mem, Kstop, e_else, arg].
  Proof.
    intros Hload.
    destruct (Z.eqb_spec n n') as [n_n'|n_n'].
    - subst n'.
      assert (Hload' := Hload).
      unfold Memory.load in Hload'.
      unfold Memory.store.
      simpl in *.
      destruct (Permission.eqb P Permission.data) eqn:EpermData; try discriminate.
      destruct (getm mem C) as [memC|] eqn:EmemC; try discriminate.
      destruct (ComponentMemory.store_after_load _ _ _ _ (Int (Z.succ n)) Hload')
        as [memC' EmemC'].
      rewrite EmemC'.
      eexists; split; eauto.
      repeat take_step; trivial; try eassumption.
      + unfold Memory.load. simpl. rewrite EmemC. eauto.
      + repeat take_step; trivial; try eassumption.
        rewrite Z.eqb_refl -[_ != _]/(true) /=.
        repeat take_step; trivial; try eassumption.
        * unfold Memory.load. simpl. rewrite EmemC. eauto.
        * unfold Memory.store. simpl. rewrite EmemC. simpl. now rewrite Z.add_1_r EmemC'.
        * apply star_refl.
    - unfold switch_clause.
      repeat take_step; trivial; try eassumption.
      + unfold Memory.load in Hload. simpl in Hload.
        destruct (Permission.eqb P Permission.data); try discriminate.
        unfold Memory.load. simpl. eauto.
      + eapply (@star_step _ _ _ _ _ _ E0 _ E0 _ E0); trivial; simpl.
        { rewrite <- Z.eqb_neq in n_n'. rewrite n_n'. simpl.
          eapply CS.KS_If2. }
        apply star_refl.
  Qed.

  (* Given an indexed switch statement [res], add a new expression [e] at the
     top. If the first available index for [res] is [n], this number is used
     to check the execution of [e], and the first available index of the result
     is [n - 1]. *)
  Definition switch_add_expr (e : expr) (res : nat * expr) : (nat * expr) :=
    (Nat.pred (fst res), switch_clause (Z.of_nat (Nat.pred (fst res))) e (snd res)).

  (* Create a base switch out of the list expressions [es ++ [e_else]]. *)
  Definition switch (es: list expr) (e_else: expr) : expr :=
    snd (fold_right switch_add_expr (length es, e_else) es).

  Lemma fst_switch n (e_else: expr) (es : list expr) :
    fst (fold_right switch_add_expr (n, e_else) es) = (n - length es)%nat.
  Proof.
    induction es as [|e' es IH]; try now rewrite Nat.sub_0_r.
    simpl. now rewrite IH Nat.sub_succ_r.
  Qed.

  Lemma switch_spec_else p' P C stk mem n es e_else arg :
    Memory.load mem (P, C, Block.local, 0%Z) = Some (Int (Z.of_nat n)) ->
    (length es <= n)%nat ->
    Star (CS.sem p')
         [CState C, stk, mem, Kstop, switch es e_else, arg] E0
         [CState C, stk, mem, Kstop, e_else, arg].
  Proof.
    intros C_local es_n. unfold switch.
    enough (forall m,
               m <= n -> length es <= m ->
               Star (CS.sem p')
                    [CState C, stk, mem, Kstop, snd (fold_right switch_add_expr (m, e_else) es), arg]
                    E0
                    [CState C, stk, mem, Kstop, e_else, arg])%nat.
    { apply (H (length es)); trivial. }
    clear es_n. intros m m_le_n es_le_n.
    induction es as [|e es IH]; try apply star_refl.
    unfold switch. simpl. simpl in es_le_n. rewrite fst_switch -Nat.sub_succ_r. simpl.
    do 5 take_step; [eauto|].
    - unfold Memory.load in C_local. simpl in C_local.
      destruct (Permission.eqb P Permission.data); try discriminate.
      unfold Memory.load. simpl. eauto.
    - do 2 take_step.
      eapply (@star_step _ _ _ _ _ _ E0); try now (simpl; reflexivity).
      { apply CS.eval_kstep_sound. simpl.
        destruct (Z.eqb_spec (Z.of_nat n) (Z.of_nat (m - S (length es)))) as [n_eq_0|?]; simpl.
        - zify. lia.
        - reflexivity. }
      apply IH. lia.
  Qed.

  Lemma switch_spec p' P C stk mem es e es' e_else arg :
    Memory.load mem (P, C, Block.local, 0%Z) = Some (Int (Z.of_nat (length es))) ->
    exists mem',
      Memory.store mem (P, C, Block.local, 0%Z) (Int (Z.of_nat (S (length es)))) = Some mem' /\
        Star (CS.sem p')
             [CState C, stk, mem , Kstop, switch (es ++ e :: es') e_else, arg] E0
             [CState C, stk, mem', Kstop, e, arg].
  Proof.
    intros Hload.
    assert (Eswitch :
             exists e_else',
               switch (es ++ e :: es') e_else =
                 switch es (switch_clause (Z.of_nat (length es)) e e_else')).
    { unfold switch. rewrite fold_right_app app_length. simpl.
      exists (snd (fold_right switch_add_expr ((length es + S (length es'))%nat, e_else) es')).
      repeat f_equal. rewrite -> surjective_pairing at 1. simpl.
      rewrite fst_switch Nat.add_succ_r.
      assert (H : (S (length es + length es') - length es' = S (length es))%nat) by lia.
      rewrite H. reflexivity. }
    destruct Eswitch as [e_else' ->]. clear e_else. rename e_else' into e_else.
    assert (Hcont := switch_clause_spec p' stk (Z.of_nat (length es)) e e_else arg Hload).
    rewrite Z.eqb_refl in Hcont.
    destruct Hcont as (mem' & Hstore & Hstar2).
    exists mem'. rewrite Nat2Z.inj_succ. split; trivial.
    apply (fun H => @star_trans _ _ _ _ _ _ E0 _ H E0 _ _ Hstar2); trivial.
    apply (switch_spec_else p' stk _ arg Hload).
    reflexivity.
  Qed.

  (* RB: NOTE: Should we try to avoid writing [Source] qualifiers all over the
     place? We are working on the source after all. *)

  (* A simple scheme that maps registers to constant memory locations
     immediately after the back-translation counter in position 0.
     RB: TODO: Phrase in terms of [Register.to_nat]. *)
  Definition reg_offset (reg : Eregister) : Z :=
    (* 4 + *)
    match reg with
    | E_R_ONE  => 4
    | E_R_COM  => 5
    | E_R_AUX1 => 6
    | E_R_AUX2 => 7
    | E_R_RA   => 8
    | E_R_SP   => 9
    | E_R_ARG  => 10
    end.

  Lemma reg_offset_inj :
    forall reg1 reg2,
      reg_offset reg1 = reg_offset reg2 ->
      reg1 = reg2.
  Proof.
    intros [] [] Heq;
      try inversion Heq;
      reflexivity.
  Qed.

  Definition loc_of_reg (reg : Eregister) : expr :=
    E_binop Add E_local (E_val (Int (reg_offset reg))).

  Lemma values_are_integers_loc_of_reg:
    forall r, Source.values_are_integers (loc_of_reg r).
  Proof.
    now destruct r.
  Qed.

  Lemma called_procedures_loc_of_reg:
    forall r, called_procedures (loc_of_reg r) = fset0.
  Proof.
    destruct r;
      (simpl; unfold fsetU, val; simpl; rewrite fset0E; reflexivity).
  Qed.

  (* Straightforward correspondence between "event" operators and
     regular operators. *)
  Definition binop_of_Ebinop (op : Ebinop) : binop :=
    match op with
    | E_Add   => Add
    | E_Minus => Minus
    | E_Mul   => Mul
    | E_Eq    => Eq
    | E_Leq   => Leq
    end.

  Definition nop_expr: expr := E_val (Int 0%Z).
  Definition error_expr : expr := E_binop Mul (E_val (Int 0)) E_local.

  Definition INITFLAG_offset := 2%Z.
  Definition LOCALBUF_offset := 3%Z.
  Definition LOCALBUF_blockid : Block.id := 1.

  Hint Unfold INITFLAG_offset : definabilitydb.
  Hint Unfold LOCALBUF_offset : definabilitydb.
  Hint Unfold LOCALBUF_blockid : definabilitydb.


  Definition INITFLAG := E_binop Add E_local (E_val (Int INITFLAG_offset)).
  Definition LOCALBUF := E_binop Add E_local (E_val (Int LOCALBUF_offset)).

  (* Translation of constant values to expressions, with special attention
     given to pointers. *)
  Definition expr_of_const_val (v : value) : expr :=
    match v with
    (* Integer values are simple. *)
    | Int n            => E_val (Int n)
    (* Pointer values need to take into account some amount of shifting, here
       corresponding to the counter and space reserved to locate register
       values.  *)
    | Ptr (perm, cid, bid, o) =>
        if Permission.eqb perm Permission.data then
          (* We make the implicit assumption that all such values refer to
           the local buffer, which should follow from well-formedness. *)
          E_binop Add (E_deref LOCALBUF) (E_val (Int o))
                  (* Ptr (perm, cid, S bid, o) *)
                  (* E_binop Add E_local (E_val (Int (8 + o))) *)
        else
          (* An implicit assumption is that perm =? Permission.code. *)
          (* TODO: change the type of the permission field so that it is not int, and
           instead just an inductive type. *)
          (* An implicit assumption is that the component id of the code pointer *)
          (* is the same as the component id of the pc. *)
          (* An implicit assumption is that the block id corresponds exactly to *)
          (* the function id. Note that this assumption is satisfied by the memory *)
          (* initialization functions. *)
          E_binop Add (E_funptr bid) (E_val (Int o))
    (* Undefined values are mapped to a well-formed but ill-typed expression
       (instead of some arbitrary but well-typed value, so as to preserve
       bad behavior). This choice might demand more work in some proofs,
       while possibly making other goals distinctly provable. *)
    | Undef            => error_expr
    end.

  Lemma values_are_integers_expr_of_const_val:
    forall v, Source.values_are_integers (expr_of_const_val v).
  Proof.
    intros [n | [[[p C] b ] o] |]; try reflexivity.
    destruct (Permission.eqb p Permission.data) eqn:e; unfold expr_of_const_val; rewrite e; auto.
  Qed.

  Lemma called_procedures_expr_of_const_val:
    forall v, called_procedures (expr_of_const_val v) = fset0.
  Proof.
    intros [n | [[[p C] b ] o] |].
    - reflexivity.
    - simpl. unfold fsetU, val. simpl. rewrite fset0E.
      destruct (Permission.eqb p Permission.data) eqn:Heq;
        simpl; rewrite !fset0U fset0E; reflexivity.
    - simpl. unfold fsetU, val. simpl. rewrite fset0E. reflexivity.
  Qed.

  (** We use [switch] to define the following function [expr_of_trace], which
      converts a sequence of events to an expression that produces that sequence
      of events when run from the appropriate component.  We assume that all
      events were produced from the same component.  The [C] and [P] arguments
      are only needed to generate the recursive calls depicted above. *)

  Notation "x ;; y" := (E_seq x y) (right associativity, at level 90).

  Definition EXTCALL_offset := 1%Z.
  Hint Unfold EXTCALL_offset : definabilitydb.
  Hint Unfold Block.local : definabilitydb.
  
  Definition EXTCALL := E_binop Add E_local (E_val (Int EXTCALL_offset)).
  Definition invalidate_metadata :=
    E_assign (loc_of_reg E_R_ONE) error_expr;;
    E_assign (loc_of_reg E_R_AUX1) error_expr;;
    E_assign (loc_of_reg E_R_AUX2) error_expr;;
    E_assign (loc_of_reg E_R_RA) error_expr;;
    E_assign (loc_of_reg E_R_SP) error_expr;;
    E_assign (loc_of_reg E_R_ARG) error_expr.

  (* We call this function when in component C executing P. *)
  Definition expr_of_event (C: Component.id) (P: Procedure.id) (e: event_inform) : expr :=
    match e with
    | ECallInform _ P' arg _ _ C' =>
        E_assign EXTCALL (E_val (Int 1%Z));;
        E_assign (loc_of_reg E_R_COM) (E_call C' P' (E_deref (loc_of_reg E_R_COM)));;
        invalidate_metadata;;
        E_assign EXTCALL (E_val (Int 0%Z));;
        E_call C P (E_val (Int 0%Z)) (* This is really (C, P) calling itself *)
    | ERetInform  _ ret_val _ _ _ =>
        E_assign EXTCALL (E_val (Int 1%Z));;
        E_deref (loc_of_reg E_R_COM)
    (* Other events generate corresponding expressions, even though these do not
       generate any events in the source semantics. Like calls (but unlike
       returns), those "informative-only" events are followed by a recursive
       call to the current procedure. *)
    | EConst _ val reg _ _ =>
        (* E_assign EXTCALL (E_val (Int 0%Z));; *)
        E_assign (loc_of_reg reg) (expr_of_const_val val);;
        E_call C P (E_val (Int 0))
    | EMov _ rsrc rdest _ _ =>
        (* E_assign EXTCALL (E_val (Int 0%Z));; *)
        E_assign (loc_of_reg rdest) (E_deref (loc_of_reg rsrc));;
        E_call C P (E_val (Int 0))
    | EBinop _ op r1 r2 r3 _ _ =>
        (* E_assign EXTCALL (E_val (Int 0%Z));; *)
        E_assign (loc_of_reg r3) (E_binop (binop_of_Ebinop op)
                                          (E_deref (loc_of_reg r1))
                                          (E_deref (loc_of_reg r2)));;
        E_call C P (E_val (Int 0))
    | ELoad _ r_src r_dest _ _ =>
        (* E_assign EXTCALL (E_val (Int 0%Z));; *)
        E_assign (loc_of_reg r_dest) (E_deref (E_deref (loc_of_reg r_src)));;
        E_call C P (E_val (Int 0))
    | EStore _ r_dest r_src _ _ =>
        (* E_assign EXTCALL (E_val (Int 0%Z));; *)
        E_assign (E_deref (loc_of_reg r_dest)) (E_deref (loc_of_reg r_src));;
        E_call C P (E_val (Int 0))
    | EAlloc _ r_dest r_size _ _ =>
        (* E_assign EXTCALL (E_val (Int 0%Z));; *)
        E_assign (loc_of_reg r_dest) (E_alloc (E_deref (loc_of_reg r_size)));;
        E_call C P (E_val (Int 0))
    end.

  (* RB: TODO: Avoid possible duplication in [Language] and [Machine]. *)
  Definition unfold_buffer (b : (nat + list value)%type) : list value :=
    match b with
    | inl n  => nseq n Undef
    | inr vs => vs
    end.

  (* The local buffer of back-translated programs is dedicated to private
     metadata:
      - The trace step counter at position 0;
      - The external call flag at position 1;
      - The buffer initialization flag at position 2;
      - The pointer to the simulated static buffer at position 3.
     These are followed by locations for the simulated machine registers.
     NOTE: Register indexes must match [loc_of_reg] and would ideally be defined
     in terms of [Register.to_nat], and their initial values in terms of
     [Register.init]. *)
  Definition meta_buffer : list value :=
    [Int 0; Int 1; Int 0; Undef] ++ [Undef; Int 0; Undef; Undef; Undef; Undef; Undef].

  (* Compute component buffer side, assuming argument [C] is in the domain of
     [intf]. *)
  Definition buffer_size (C : Component.id) : nat :=
    match prog_buffers C with
    | Some buf => size (unfold_buffer buf)
    | None => 0 (* Should not happen *)
    end.

  (* Allocate a new buffer to serve as the local buffer of the back-translation.
     By convention this will be created immediately after program initialization
     and therefore its block identifier should be 1.

     NOTE: We are relying on knowledge of the implementation and behavior of the
     allocator. If these conditions are not satisfied, the offset shifting
     necessary for the trace relation will be incorrect.

     Note that buffers coming from well-formed program components must have size
     strictly greater than zero, so the behavior of alloc() is defined. *)
  Definition alloc_local_buffer_expr (C : Component.id) : expr :=
    E_alloc (E_val (Int (Z.of_nat (buffer_size C)))).

  (* Copy the [i]-th component of the original program buffer of [C] from its
     temporary location in the local buffer of [C]'s back-translation (following
     its private metadata) into the [i]-th component of the replacement local
     buffer.

     Initially, the back-translated component memory looks like this:
       0: [M, M, M, M, M, M, M, M, D1, D2, ..., Di, ...]
     where the first few positions of the local buffer are taken up by
     (M)etadata, followed by the original component's (D)ata. During this
     process, the local, unshareable data is transferred to the de facto,
     shareable local buffer:
       L: [D1, D2, ..., Di, ...]

     Generated instruction:
       ( *(local[0]) )[i] = *( local[i + META_SIZE] )

     NOTE: Because the local buffers contain no pointers, we could write
     hardcoded initialization code instead of having a copy of the original
     local buffer in the metadata buffer.
   *)

  (* To initialize the acting local buffer from its temporary location in the
     private local buffer, allocate a new block of adequate size in memory,
     temporarily keeping its address in local[0]; use this convention to
     initialize the public local buffer; and restore the temporary variable
     to its proper value.

     NOTE: This is not so nice as we are not using the definition of
     [meta_buffer] to restore the initial value. In addition to this, using
     the first position, which holds the program counter, while noting that
     this instruction will be executed at the first value of the counter (and
     prior to its increment), is rather ugly and brittle. *)

  Definition comp_call (C : Component.id) (e : event_inform) : bool :=
    match e with
    | ECallInform _ _ _ _ _ C' => C' == C
    | _ => false
    end.

  (* RB: TODO: Treatment for [Component.main]. *)
  (* TODO: Easier to add the prologue to all procedures and control its
     execution through additional counter conditions. *)
  Definition first_proc_in_comp (C : Component.id) (P : Procedure.id)
             (t : trace event_inform) : bool :=
    match ohead (filter (comp_call C) t) with
    | Some (ECallInform _ P' _ _ _ _) => P' == P
    | _ => false
    end.

  (* RB: TODO: Later in [definability_gen] there are explicit instances of
     this function, which annoyingly will need an additional boolean
     argument. Ideally this parameter would not appear explicitly, but at the
     moment this is passed the [comp_subtrace] of the original trace, and so
     the necessary events for the initialization check are not available. *)
  Definition expr_of_trace
             (C: Component.id) (P: Procedure.id) (t: trace event_inform)
    (* (init: bool) *)
    : expr :=
    (* let init_expr := if init then [init_local_buffer_expr C] else [] in *)
    switch (map (expr_of_event C P) t) E_exit.

  (** To compile a complete trace mixing events from different components, we
      split it into individual traces for each component and apply
      [expr_of_trace] to each one of them.  We also initialize the memory of
      each component to hold 0 at the first local variable. *)

  Definition comp_subtrace (C: Component.id) (t: trace event_inform) :=
    filter (fun e => C == cur_comp_of_event e) t.

  Lemma comp_subtrace_app (C: Component.id) (t1 t2: trace event_inform) :
    comp_subtrace C (t1 ++ t2) = comp_subtrace C t1 ++ comp_subtrace C t2.
  Proof. apply: filter_cat. Qed.

  Definition buffer_nth (C : Component.id) (i : nat) : expr :=
    match prog_buffers C with
    | Some buf =>
        match nth_error (unfold_buffer buf) i with
        | Some Undef => error_expr (* Ensures no Undef appears literaly *)
        | Some v => E_val v
        | None => error_expr (* should not happen *)
        end
    | None => error_expr (* should not happen *)
    end.

  Definition copy_local_datum_expr (C : Component.id) (i : nat) : expr :=
    E_assign
      (E_binop Add (E_deref LOCALBUF)
               (E_val (Int (Z.of_nat i))))
      (buffer_nth C i).

  Definition init_local_buffer_expr (C : Component.id) : expr :=
    (* [E_assign E_local (alloc_local_buffer_expr C)] ++ *)
    (* map (copy_local_datum_expr C) (iota 0 (buffer_size C)) ++ *)
    (* [E_assign E_local (E_val (Int 0))] *)
    foldr (fun e acc => E_seq e acc)
          (E_assign INITFLAG (E_val (Int 1))) (* last instruction *)
          (map (copy_local_datum_expr C) (iota 0 (buffer_size C))).

  Definition init_check (C : Component.id): expr :=
    E_if (E_binop Eq (E_deref INITFLAG) (E_val (Int 0%Z)))
         ((E_assign LOCALBUF (E_alloc (E_val (Int (Z.of_nat (buffer_size C))))));;
          init_local_buffer_expr C)
         nop_expr.

  Definition extcall_check: expr :=
    E_if (E_binop Eq (E_deref EXTCALL) (E_val (Int 1%Z)))
         (invalidate_metadata;;
          E_assign (loc_of_reg E_R_COM) E_arg;;
          E_assign EXTCALL (E_val (Int 0%Z)))
         nop_expr.

  Definition procedure_of_trace
             (C : Component.id) (P : Procedure.id) (t : trace event_inform)
    : expr :=
    init_check C;;
    extcall_check;;
    expr_of_trace C P (comp_subtrace C t). (* RB: TODO: Substitute check. *)

  Fixpoint procedure_ids_of_subtrace
           (t: trace event_inform) :=
    match t with
    | nil => fset0
    | e :: t' =>
        let procs_of_e :=
          match e with
          | EConst _ (Ptr (Permission.code, cid, bid, off)) _ _ _ =>
              (* What we are collecting right now is a superset of the bids that
               really correspond to a procedure id. *)
              (* If we want to make this superset tighter, then we should check *)
              (* that perm =? Permission.code and that cid =? C *)
              fset1 bid
          | _ => fset0
          end
        in
        procs_of_e :|: procedure_ids_of_subtrace t'
    end.

  Definition procedure_ids_of_trace (C: Component.id) (t: trace event_inform) :=
    procedure_ids_of_subtrace (comp_subtrace C t).

  Definition code_pointer_of_event (e: event_inform) :
    option (Component.id * Procedure.id) :=
    match e with
    | EConst _ (Ptr (Permission.code, cid, bid, off)) _ _ _ => Some (cid, bid)
    | _ => None
    end.

  Definition exported_procedures_of_trace (t: trace event_inform)
    : NMap (NMap expr) :=
    mapim
      (
        fun C Ciface =>
          let exported_procs := Component.export Ciface in
          let exported_procs_with_main :=
            if C == Component.main then
              Procedure.main |: exported_procs
            else
              exported_procs
          in
          mkfmapf (fun P => procedure_of_trace C P t) exported_procs_with_main
      )
      intf.

  Fixpoint procedures_of_trace_recursive
           (whole_trace: trace event_inform)
           (suffix: trace event_inform)
           (procs_init: NMap (NMap expr))
    (** Pass the exported procedures as procs_init.                    *)
    (** Return None when a code pointer points to a cid that is not in *)
    (** the domain of procs_accum.                                     *)
    : option (NMap (NMap expr)) :=
    match suffix with
    | nil => Some procs_init
    | e :: suffix' =>
        match code_pointer_of_event e with
        | Some (cid, pid) =>
            if cid == cur_comp_of_event e
            then
              match procedures_of_trace_recursive
                      whole_trace
                      suffix'
                      procs_init
              with
              | Some res_suffix' =>
                  (* Look up the code pointer in the result of the recursive call *)
                  match res_suffix' cid with
                  | Some procs_of_cid =>
                      (* cid found. Update the procs_of_cid map by adding the code of pid *)
                      let updated_procs :=
                        setm
                          procs_of_cid
                          pid
                          (procedure_of_trace cid pid whole_trace)
                      in
                      Some (setm res_suffix'
                                 cid
                                 updated_procs)
                  | None =>
                      (*****************************************
              (* cid not found. Start from an empty procedures map for cid. *)
              let singleton_procs_map :=
                  setm
                    emptym
                    pid
                    (procedure_of_trace cid pid whole_trace)
              in
              Some (setm res_suffix' 
                         cid
                         singleton_procs_map)
                       ********************************)
                      None
                  end
              | None =>
                  (* Recursive call is None *)
                  None
              end
            else None
        | None =>
            (* No code pointer extracted from event e -- proceed to suffix'. *)
            procedures_of_trace_recursive whole_trace suffix' procs_init
        end
    end.

  Definition procedures_of_trace t : option (NMap (NMap expr)) :=
    (** Can return None but only if the trace is not well formed. *)
    let initial_procs := exported_procedures_of_trace t in
    procedures_of_trace_recursive t t initial_procs.

  (* FIXME *)
  Definition valid_procedure C P t :=
    C = Component.main /\ P = Procedure.main
    \/ exported_procedure intf C P
    \/ P \in procedure_ids_of_trace C t.

  Lemma find_procedure_exported_procedures_of_trace_case1 t C P:
    exported_procedure intf C P ->
    Source.find_procedure (exported_procedures_of_trace t) C P
    = Some (procedure_of_trace C P t).
  Proof.
    unfold Source.find_procedure, exported_procedures_of_trace.
    intros [CI [C_CI CI_P]].
    rewrite mapimE C_CI /= mkfmapfE.
    case: eqP=> _; unfold Component.is_exporting in *.
    - by rewrite in_fsetU1 CI_P !orbT.
    - by rewrite CI_P.
  Qed.

  Lemma find_procedure_exported_procedures_of_trace_case2 t:
    Source.find_procedure (exported_procedures_of_trace t)
                          Component.main
                          Procedure.main
    = Some (procedure_of_trace Component.main Procedure.main t).
  Proof.
    unfold Source.find_procedure, exported_procedures_of_trace.
    rewrite mapimE /=. unfold omap, obind, oapp.
    destruct (intf Component.main); [|discriminate].
    by rewrite mkfmapfE in_fsetU1 eqxx orTb.
  Qed.

  Lemma find_procedure_Some_preserved_by_procedures_of_trace_recursive 
        (whole_trace t: trace event_inform) procs_map procs_map':
    (forall C' P' exp',
        Source.find_procedure procs_map C' P' = Some exp' ->
        exp' = procedure_of_trace C' P' whole_trace
    )
    ->
      procedures_of_trace_recursive
        whole_trace t procs_map = Some procs_map' ->
    (forall C P exp,
        Source.find_procedure procs_map C P = Some exp ->
        Source.find_procedure procs_map' C P = Some exp
    ).
  Proof.
    revert procs_map'.
    induction t as [|e t']; intros ? Hassm HSome ? ? ? Hfind; simpl in *;
      [by inversion HSome as [H]; subst; auto|].
    destruct (code_pointer_of_event e) as [[cid pid]|] eqn:ecode_pointer;
      last first.
    - by eapply IHt'; eauto.
    - destruct (cid == cur_comp_of_event e) eqn:ecid; rewrite ecid in HSome;
        [|discriminate].
      destruct (procedures_of_trace_recursive whole_trace t' procs_map)
        as [procs_of_cid|] eqn:eprocs_of_cid; [|discriminate].
      destruct (procs_of_cid cid) as [procscid|] eqn:eprocscid; [|discriminate];
        inversion HSome; subst; clear HSome; unfold Source.find_procedure;
        rewrite setmE.
      + find_if_inside_goal.
        * rewrite setmE. move : e0 => /eqP => ?; subst.
          find_if_inside_goal.
          -- specialize (Hassm _ _ _ Hfind). subst. move : e0 => /eqP => ?; by subst.
          -- specialize (IHt' _ Hassm Logic.eq_refl _ _ _ Hfind).
             unfold Source.find_procedure in IHt'. by rewrite eprocscid in IHt'.
        * specialize (IHt' _ Hassm Logic.eq_refl _ _ _ Hfind).
          by unfold Source.find_procedure in IHt'.             
  Qed.
  
  Lemma find_procedures_of_trace_exp_helper
        (whole_trace t: trace event_inform) procs_map:
    (
      forall C' P' exp',
        Source.find_procedure procs_map C' P' = Some exp' ->
        exp' = procedure_of_trace C' P' whole_trace
    )
    ->
      forall C P exp procs_map',
        procedures_of_trace_recursive
          whole_trace t procs_map = Some procs_map' ->
        Source.find_procedure procs_map' C P = Some exp ->
        exp = procedure_of_trace C P whole_trace.
  Proof.
    unfold Source.find_procedure. revert procs_map.
    induction t as [|e t']; intros ? Hprocs_map ? ? ? ? HSome H; subst;
      simpl in *; inversion HSome; subst.
    - by eapply Hprocs_map; eauto.
    - destruct (code_pointer_of_event e) as [[cid pid]|] eqn:ecode_pointer;
        last first.
      + by apply (IHt' procs_map Hprocs_map C P exp _ HSome).
      + destruct (cid == cur_comp_of_event e) eqn:ecid; rewrite ecid in HSome;
          [|discriminate].
        destruct (procedures_of_trace_recursive whole_trace t' procs_map)
          as [procs_of_cid|] eqn:eprocs_of_cid; [|discriminate].
        destruct (procs_of_cid cid) as [procscid|] eqn:eprocscid; [|discriminate].
        * rewrite ecid in H1.
          inversion H1; subst. clear H1 HSome.
          rewrite setmE in H.
          destruct (C == cid) eqn:eC_cid; [move : eC_cid => /eqP => ?; subst|].
          -- rewrite eqxx in H. rewrite setmE in H.
             destruct (P == pid) eqn:eP_pid;
               [move:eP_pid=> /eqP=> ?; subst; rewrite eqxx in H; by inversion H
               |rewrite eP_pid in H].
             eapply (IHt' procs_map Hprocs_map cid P exp _ eprocs_of_cid);
               eauto. by rewrite eprocscid.
          -- rewrite eC_cid in H.
             by apply (IHt' procs_map Hprocs_map C P exp _ eprocs_of_cid).
  Qed.

  Lemma exported_procedures_of_trace_Some_find_procedure t:
    forall C' P' exp',
      Source.find_procedure (exported_procedures_of_trace t) C' P' =
        Some exp' ->
      exp' = procedure_of_trace C' P' t.
  Proof.
    unfold Source.find_procedure, exported_procedures_of_trace. intros ? ? ?.
    rewrite mapimE. unfold omap, obind, oapp.
    destruct (intf C') as [C'i|] eqn:eintf; [|discriminate].
    rewrite mkfmapfE.
    find_if_inside_goal; [|discriminate].
    find_if_inside_hyp e; (by intros H; inversion H; subst).
  Qed.
  
  Lemma find_procedures_of_trace_exp (t: trace event_inform) C P procs_map:
    procedures_of_trace t = Some procs_map ->
    exported_procedure intf C P ->
    Source.find_procedure procs_map C P
    = Some (procedure_of_trace C P t).
  Proof.
    unfold procedures_of_trace.
    intros HSome Hexport.
    specialize (@exported_procedures_of_trace_Some_find_procedure t) as Hassm.
    specialize (@find_procedures_of_trace_exp_helper t t _ Hassm) as G.
    eapply find_procedure_Some_preserved_by_procedures_of_trace_recursive.
    2 : { exact HSome. }
    - exact Hassm.
    - by apply find_procedure_exported_procedures_of_trace_case1; auto.
  Qed.

  Lemma find_procedures_of_trace_main (t: trace event_inform) procs_map:
    procedures_of_trace t = Some procs_map ->
    Source.find_procedure procs_map Component.main Procedure.main
    = Some (procedure_of_trace Component.main Procedure.main t).
  Proof.
    unfold procedures_of_trace.
    intros HSome.
    specialize (@exported_procedures_of_trace_Some_find_procedure t) as Hassm.
    specialize (@find_procedures_of_trace_exp_helper t t _ Hassm) as G.
    eapply find_procedure_Some_preserved_by_procedures_of_trace_recursive.
    2 : { exact HSome. }
    - exact Hassm.
    - by apply find_procedure_exported_procedures_of_trace_case2; auto.
  Qed.

  Lemma find_procedures_of_trace (t: trace event_inform) C P procs_map:
    procedures_of_trace t = Some procs_map ->
    C \in domm intf ->
          valid_procedure C P t ->
          Source.find_procedure procs_map C P = Some (procedure_of_trace C P t).
  Proof.
    intros HSome.
    move=> /dommP [CI C_CI] [[-> ->]|[?|H]]; [auto|auto|].
    - eapply find_procedures_of_trace_main; eauto.
    - eapply find_procedures_of_trace_exp; eauto.
    - move: H HSome.
      rewrite /Source.find_procedure /procedures_of_trace
              /procedure_ids_of_trace.
      intros H HSome.
      assert (LEMMA:
               forall wholet,
                 procedures_of_trace_recursive wholet t
                                               (exported_procedures_of_trace wholet)
                 = Some procs_map ->
                 match procs_map C with
                 | Some C_procs => C_procs P
                 | None => None
                 end = Some (procedure_of_trace C P wholet)
             ).
      {
        clear HSome.
        generalize dependent procs_map.
        induction t; intros ? ? HSome.
        + by rewrite in_fset0 in H.
        + simpl in H.
          destruct (C == cur_comp_of_event a) eqn:eC; rewrite eC in H.
          * rewrite in_fsetU in H.
            move : H => /orP => [[H1 | H2]].
            -- destruct a; try by rewrite in_fset0 in H1.
               destruct v as [| [[[[] c] b] o] |]; try by rewrite in_fset0 in H1.
               rewrite in_fset1 in H1. move : H1 => /eqP => H1; subst.
               (** HSome should solve the goal. by simpl and rewriting setmE somehow*)
               simpl in HSome. simpl in eC.
               move : eC => /eqP => eC; subst.
               destruct (c == i) eqn:ei'; [|discriminate].
               move : ei' => /eqP => ?; subst.
               destruct (procedures_of_trace_recursive
                           wholet t (exported_procedures_of_trace wholet))
                 as [procs_map'|] eqn:eprocs_map';
                 [|discriminate].
               destruct (procs_map' i) as [entry|] eqn:eentry; [|discriminate].
               ++ inversion HSome as [H0]. rewrite setmE eqxx. 
                  by rewrite setmE eqxx; eauto.

            -- specialize (IHt H2).
               simpl in HSome.
               destruct (code_pointer_of_event a) as [[cid pid]|] eqn:ecodeptr.
               ++ destruct (cid == cur_comp_of_event a) eqn:ecid;
                    rewrite ecid in HSome; [|discriminate].
                  destruct (procedures_of_trace_recursive
                              wholet t (exported_procedures_of_trace wholet))
                    as [procs_map'|] eqn:eprocs_map';
                    [|discriminate].
                  destruct (procs_map' cid) as [procs_map_entry|] eqn:eentry;
                    [|discriminate].
                  ** specialize (IHt _ _ eprocs_map').
                     inversion HSome as [H0]. clear HSome. rewrite setmE.
                     destruct (C == cid) eqn:eC2; [|assumption].
                     assert (HTrue: cid = cur_comp_of_event a).
                     {
                       move : eC => /eqP => eC. subst.
                       move : eC2 => /eqP => eC2. by subst.
                     }
                     subst. rewrite setmE.
                     destruct (P == pid) eqn:eP; rewrite eP.
                     --- move : eP => /eqP => ?; subst.
                         move : eC2 => /eqP => ?; by subst.
                     --- move : eC => /eqP => ?; subst. by rewrite eentry in IHt.

               ++ by specialize (IHt _ _ HSome).
          * specialize (IHt H).
            simpl in HSome.
            destruct (code_pointer_of_event a) as [[cid pid]|] eqn:ecodeptr.
            ++ destruct (cid == cur_comp_of_event a) eqn:ecid;
                 rewrite ecid in HSome; [|discriminate].
               destruct (procedures_of_trace_recursive
                           wholet t (exported_procedures_of_trace wholet))
                 as [procs_map'|] eqn:eprocs_map';
                 [|discriminate].
               destruct (procs_map' cid) as [procs_map_entry|] eqn:eentry;
                 [|discriminate].
               ** specialize (IHt _ _ eprocs_map').
                  inversion HSome as [H0]. clear HSome. rewrite setmE.
                  destruct (C == cid) eqn:eC2; [|assumption].
                  move : eC2 => /eqP => ?; subst.
                  rewrite setmE.
                  destruct (P == pid) eqn:eP; rewrite eP.
                  --- move : eP => /eqP => ?; by subst.
                  --- by rewrite eentry in IHt.
            ++ by specialize (IHt _ _ HSome).
      }
      eapply LEMMA; eauto.
  Qed.    

  Search valid_procedure.
  
  Lemma find_procedures_of_trace_Some_procedure_of_trace
        (t: trace event_inform) C P procs_map Pexpr:
    procedures_of_trace t = Some procs_map ->
    C \in domm intf ->
          Source.find_procedure procs_map C P = Some Pexpr ->
          Pexpr = procedure_of_trace C P t.
  Proof.
    rewrite /procedures_of_trace /procedure_ids_of_trace.
    intros HSome Hdomm Hfind.
    assert (LEMMA:
             forall wholet procs_map Pexpr,
               procedures_of_trace_recursive wholet t
                                             (exported_procedures_of_trace wholet)
               = Some procs_map ->
               Source.find_procedure procs_map C P = Some Pexpr ->
               Pexpr = procedure_of_trace C P wholet
           ).
    {
      clear HSome Hfind procs_map Pexpr.
      induction t; auto; simpl in *; intros ? ? ? HSome Hfind; auto.
      - inversion HSome; subst. clear HSome.
        eapply exported_procedures_of_trace_Some_find_procedure; eauto.
      - destruct (code_pointer_of_event a) as [[cid pid]|] eqn:ecodeptr.
        + destruct (cid == cur_comp_of_event a) eqn:ecid;
            rewrite ecid in HSome; [|discriminate].
          move : ecid => /eqP => ?; subst.
          destruct (procedures_of_trace_recursive
                      wholet t (exported_procedures_of_trace wholet))
            as [procs_map'|] eqn:eprocs_map';
            [|discriminate].
          destruct (procs_map' (cur_comp_of_event a)) as [procs_map_entry|] eqn:eentry;
            [|discriminate].
          specialize (IHt _ _ Pexpr eprocs_map').
          inversion HSome as [H0]. clear HSome. subst.
          destruct a eqn:ea; try discriminate. simpl in *.
          unfold Source.find_procedure in *.
          rewrite setmE in Hfind.
          find_if_inside_hyp Hfind.
          * move : e0 => /eqP => ?; subst. rewrite eentry in IHt.
            rewrite setmE in Hfind. find_if_inside_hyp Hfind.
            -- move : e0 => /eqP => ?; subst. by inversion Hfind.
            -- by eapply IHt.
          * by eapply IHt.
        + by eapply IHt; eauto.
    }
    by eapply LEMMA; eauto.
  Qed.
  
  Definition program_of_trace (t: trace event_inform) : option Source.program :=
    match procedures_of_trace t with
    | Some procs_map => Some
                          {| Source.prog_interface  := intf;
                            Source.prog_procedures := procs_map;
                            Source.prog_buffers    :=
                            mapm (fun _ => inr meta_buffer) intf |}
    | None => None
    end.
  (* mapm (fun b => inr (meta_buffer ++ (unfold_buffer b))) prog_buffers |}. *)

  (** To prove that [program_of_trace] is correct, we need to describe how the
      state of the program evolves as it emits events from the translated trace.
      One of the difficulties is the stack.  If a call to a component [C]
      performs [n] calls to other components before returning, the code
      generated by [expr_of_trace] will perform [n] *internal* calls in [C].
      Thus, the final return to the calling component must be preceded by [n]
      returns from those recursive calls.  We describe this pattern with the
      following properties.  *)

  Fixpoint well_formed_callers (callers: list Component.id) (stk: CS.stack) (mem: Memory.t) (t: trace event_inform) : Prop :=
    match callers with
    | [] => True
    | C :: callers' =>
        Memory.load mem (Permission.data, C, Block.local, INITFLAG_offset) = Some (Int 1%Z) /\
          (exists v P top bot,
              stk = CS.Frame C v (Kassign1 (loc_of_reg E_R_COM)
                                           (Kseq
                                              (invalidate_metadata;; E_assign EXTCALL (E_val (Int 0));; E_call C P (E_val (Int 0)))
                                              Kstop))  :: top ++ bot /\
                valid_procedure C P t /\
                All (fun '(CS.Frame C' _ k) => C' = C /\ k = Kstop) top /\
                well_formed_callers callers' bot mem t)
    end.

  Definition well_formed_stack (s: stack_state) (stk: CS.stack) (mem: Memory.t) (t: trace event_inform) : Prop :=
    exists top bot,
      stk = top ++ bot /\
        All (fun '(CS.Frame C' _ k) => C' = cur_comp s /\ k = Kstop) top /\
        well_formed_callers (callers s) bot mem t.

  (** The read and write events will also need to rely on the paths. Should the
      (read and write?) events include the paths so as to make back-translation
      easier?

      Would this be the path from the local buffer? *)

  (* ... *)

  (** Main proof of back-translation *)

  (* TODO: In the back-translation of a program, every call that appears in the
     code of a function is either a call to a valid procedure or a call to
     itself (and in the latter case it is necessarily defined).

     Internal functions are back-translated but never called; their bodies are
     generated by the same procedure as exported functions, but this distinction
     is not really important. *)
  
  Lemma well_formed_events_procedures_of_trace_Some T (procs: NMap (NMap T)) t:
    domm procs = domm (exported_procedures_of_trace t) ->
    all (well_formed_event intf procs) t ->
    exists procs_map, procedures_of_trace t = Some procs_map
                      /\ domm procs_map = domm procs.
  Proof.
    Local Opaque cur_comp_of_event.
    intros Hdomm Ht.
    unfold procedures_of_trace.
    assert (LEMMA: forall wholet,
               domm procs = domm (exported_procedures_of_trace wholet) ->
               all (well_formed_event intf procs) t ->
               exists procs_map,
                 procedures_of_trace_recursive wholet t
                                               (exported_procedures_of_trace wholet)
                 = Some procs_map
                 /\
                   domm procs_map = domm procs
           ).
    {
      clear Hdomm Ht. induction t; intros ? Hdomm Ht.
      - by simpl; eauto.
      - unfold well_formed_event in Ht. simpl in Ht. move : Ht => /andP => [[Ht1 Ht2]].
        simpl.
        specialize (IHt wholet Hdomm Ht2) as [procs_mapIH [Hprocs_mapIH HdommIH]].
        rewrite Hprocs_mapIH.
        destruct (code_pointer_of_event a) as [[cid pid]|] eqn:ecidpid; [|by eauto].
        assert (H: cid == cur_comp_of_event a).
        {
          Local Transparent cur_comp_of_event.
          destruct a; simpl in *; try discriminate; auto.
          unfold well_formed_constant_value in Ht1.
          destruct v as [| [[[[] c] b] o] |]; try discriminate.
          inversion ecidpid; subst.
          destruct (procs i); auto. move : Ht1 => /andP => [[G ?]].
          by auto.
        }
        rewrite H.
        destruct (procs_mapIH cid) eqn:ecid; eauto.
        + destruct a; simpl in *; try discriminate.
          move : H => /eqP => ?; subst.
          destruct v as [| [[[[] ?] ?] ? ]|]; try discriminate.
          inversion ecidpid; subst. simpl in Ht1.
          eexists; split; [reflexivity|].
          rewrite domm_set. rewrite fsetU1in; auto. apply/dommP; eauto.
        + destruct a; simpl in *; try discriminate.
          move : H => /eqP => ?; subst.
          destruct v as [| [[[[] ?] ?] ? ]|]; try discriminate.
          inversion ecidpid; subst. simpl in Ht1.
          destruct (procs i) eqn:eprocs; [|discriminate].
          assert (contra: i \in domm (procs_mapIH)).
          {
            rewrite HdommIH. by apply/dommP; eauto.
          }
          move : contra => /dommP => [[? Hrewr]]. by rewrite Hrewr in ecid. 
    }
    specialize (LEMMA _ Hdomm Ht) as [? [? ?]]. by eauto.
  Qed.

  Lemma domm_exported_procedures_of_trace_interface t:
    domm (exported_procedures_of_trace t) = domm intf.
  Proof. unfold exported_procedures_of_trace. by rewrite domm_mapi. Qed.

  Lemma well_formed_events_bigger_map
        T t (procs: NMap (NMap T)) cid pid old_inner_procs (newT: T):
    all (well_formed_event intf procs) t ->
    procs cid = Some old_inner_procs ->
    all (well_formed_event intf
                           (setm procs cid (setm old_inner_procs pid newT))
        ) t.
  Proof.
    induction t; intros Hwf HSome; auto; simpl in *.
    move : Hwf => /andP => [[Hwf1 Hwf2]].
    specialize (IHt Hwf2 HSome).
    apply/andP; split; [|assumption].
    destruct a; auto; simpl in *.
    destruct v as [| [[[ [] ?] ?] ?] |]; auto; simpl in *; try discriminate.
    rewrite setmE.
    destruct (procs i) as [procs_i|] eqn:eprocsi; [|discriminate].
    find_if_inside_goal; auto. rewrite setmE.
    move : Hwf1 => /andP => [[G ?]]. 
    find_if_inside_goal; auto; simpl.
    - by rewrite G.
    - rewrite G. move : e0 => /eqP => ?; subst.
      rewrite HSome in eprocsi. inversion eprocsi; subst. by auto.
  Qed.

  Lemma well_formed_events_procs_procedures_of_trace
        T (procs: NMap (NMap T)) procs_map t:
    all (well_formed_event intf procs) t ->
    procedures_of_trace t = Some procs_map ->
    all (well_formed_event intf procs_map) t.
  Proof.
    unfold procedures_of_trace.
    assert (LEMMA:
             forall wholet procs_map,
               all (well_formed_event intf procs) t ->
               procedures_of_trace_recursive
                 wholet t (exported_procedures_of_trace wholet) = Some procs_map ->
               all (well_formed_event intf procs_map) t
           ).
    {
      clear procs_map.
      induction t; intros ? ? Hwfprocs HSome; auto.
      simpl in *.
      destruct (code_pointer_of_event a) as [[cid pid]|] eqn:ecode_ptr; last first;
        move : Hwfprocs => /andP => [[Hwfprocs1 Hwfprocs2]].        
      - specialize (IHt _ _ Hwfprocs2 HSome).
        apply/andP; split; [|assumption].
        destruct a eqn:ea; auto.
        destruct v as [| [[[ [] ?] ?] ?] |]; auto; simpl in *; discriminate.
      - find_if_inside_hyp HSome; [|discriminate].
        destruct (procedures_of_trace_recursive
                    wholet t (exported_procedures_of_trace wholet))
          as [res_suffix'|] eqn:eprocs; [|discriminate].
        destruct (res_suffix' cid) as [procs_of_cid|] eqn:ecid; [|discriminate].
        inversion HSome; subst; clear HSome.
        specialize (IHt _ _ Hwfprocs2 eprocs).
        destruct a; try discriminate. move : e => /eqP => ?; subst. simpl in *.
        destruct v as [| [[[ [] ?] ?] ?] |]; auto; try discriminate.
        inversion ecode_ptr; subst; clear ecode_ptr.
        simpl in *. rewrite setmE eqxx setmE eqxx. simpl.
        rewrite Nat.eqb_refl !andTb.
        destruct (procs i) as [procs_i|] eqn:eprocsi; [|discriminate].
        eapply well_formed_events_bigger_map; eauto.
    }
    eapply LEMMA; by eauto.
  Qed.
  
  Lemma well_formed_events_well_formed_program T (procs: NMap (NMap T)) t :
    domm procs = domm (exported_procedures_of_trace t) ->
    all (well_formed_event intf procs) t ->
    exists p, program_of_trace t = Some p
              /\
                Source.well_formed_program p.
  Proof.
    Local Opaque loc_of_reg binop_of_Ebinop expr_of_const_val.
    move=> Hdomm Ht.
    assert (exists procs_map, procedures_of_trace t = Some procs_map /\
                                domm procs_map = domm procs)
      as [procs_map [Hprocs_map Hprocs_map_domm]].
    {
      eapply well_formed_events_procedures_of_trace_Some; by eauto.
    }
    unfold program_of_trace. rewrite Hprocs_map. eexists; split; eauto.
    split=> //=.
    - exact: closed_interface_is_sound.
    - erewrite Hprocs_map_domm, <- domm_exported_procedures_of_trace_interface.
      symmetry. eassumption.
    - move=> C P.
      rewrite /exported_procedure /Program.has_component /Component.is_exporting.
      case=> CI [C_CI P_CI].
      erewrite find_procedures_of_trace_exp; eauto. exists CI; split; by eauto.
    - move=> C P Pexpr Hfind.
      assert (HCintf: C \in domm intf).
      {
        erewrite <- domm_exported_procedures_of_trace_interface,
          <- Hdomm, <- Hprocs_map_domm.
        unfold Source.find_procedure in *.
        destruct (procs_map C) as [Cmap|] eqn:eC; [|discriminate].
        by apply/dommP; eauto.
      }
      case intf_C: (intf C)=> [CI|] //=; last first.
      {
        move : HCintf => /dommP => [[? contra]]. by rewrite contra in intf_C.
      }
      unfold Source.well_formed_expr; simpl.
      assert (H_: Pexpr = procedure_of_trace C P t).
      {
        by eapply find_procedures_of_trace_Some_procedure_of_trace; eauto.
      }
      subst.
      (*rewrite mkfmapfE; case: ifP=> //= P_CI [<-] {Pexpr};*)
      split; last first.
      + split.
        * rewrite /procedure_of_trace /expr_of_trace /switch.
          simpl. repeat (rewrite <- andbA; simpl).
          rewrite !values_are_integers_loc_of_reg; simpl.
          apply /andP. split.
          { rewrite /init_local_buffer_expr /buffer_size.
            case eq_buf: (prog_buffers C) => [buf|] //=.
            generalize dependent 0.
            elim: (unfold_buffer buf).
            - by [].
            - move=> v ls IH n //=.
              rewrite IH.
              move: (wf_buffers eq_buf).
              rewrite /Buffer.well_formed_buffer /buffer_nth eq_buf
                      /unfold_buffer.
              case: buf {eq_buf} => [p | buf] //=.
              + move=> _.
                elim: p n => [| p IH' n].
                * by destruct n.
                * case n => //=.
              + move=> /andP [] _ all_wf.
                elim: buf all_wf n.
                * destruct n; auto.
                * move=> v' buf IH' /andP [] [] wf_v' all_wf.
                  destruct n => //=.
                  -- simpl. destruct v'; try reflexivity.
                     by simpl in wf_v'.
                  -- by rewrite IH'.
          }
          elim: {t Ht intf_C Hdomm Hprocs_map Hfind} (comp_subtrace C t) (length _) => [|e t IH] n //=.
          by case: e=> /=; intros;
                       try rewrite values_are_integers_expr_of_const_val;
                       apply IH.
        *
          rewrite /procedure_of_trace /expr_of_trace /switch
                  /program_of_trace.
          Local Transparent loc_of_reg. simpl. Local Opaque loc_of_reg.
          rewrite andbT.
          apply /andP. split.
          { rewrite /init_local_buffer_expr /buffer_size.
            case eq_buf: (prog_buffers C) => [buf|] //=.
            generalize dependent 0.
            elim: (unfold_buffer buf).
            - by [].
            - move=> v ls IH n //=.
              rewrite IH.
              move: (wf_buffers eq_buf).
              rewrite /Buffer.well_formed_buffer /buffer_nth eq_buf
                      /unfold_buffer.
              case: buf {eq_buf} => [p | buf] //=.
              + move=> _.
                elim: p n => [| p IH' n].
                * by destruct n.
                * case n => //=.
              + move=> /andP [] _ all_wf.
                elim: buf all_wf n.
                * destruct n; auto.
                * move=> v' buf IH' /andP [] [] wf_v' all_wf.
                  destruct n => //=.
                  -- simpl. destruct v'; try reflexivity.
                  -- by rewrite IH'.
          }
          unfold program_of_trace in *.
          (* remember (procedures_of_trace t) as ps. *)

          specialize (well_formed_events_procs_procedures_of_trace Ht Hprocs_map)
            as Ht_procs_map. 

          assert (Ht': all (well_formed_event intf procs_map) (comp_subtrace C t)).
          {
            clear -Ht_procs_map.
            induction t; auto. simpl in Ht_procs_map.
            move : Ht_procs_map => /andP [[G1 G2]].
            specialize (IHt G2).
            simpl in *.
            find_if_inside_goal; auto. simpl in *. by rewrite G1 IHt.
          }
          assert (Ht'': all (fun e => cur_comp_of_event e == C) (comp_subtrace C t)).
          { clear -Ht.
            elim: t Ht => //= e t IH /andP [] wf /IH all_eq.
            case: ifP=> /eqP eq //=. subst C. by apply /andP. }
          elim: {Ht intf_C} (comp_subtrace C t) (length _) Ht' Ht'' =>
                //= e t' IH n /andP [] wf_e wf_all /andP [] eq_e eq_all //=.
          Local Transparent loc_of_reg.
          destruct e => //=; intros; try by rewrite IH.
          (* Local Transparent expr_of_const_val. *)
          rewrite IH; try assumption.
          destruct v as [| [[[[]]]] |] => //=.
          simpl in *. move: eq_e => /eqP eq_e; subst i.
          Local Transparent expr_of_const_val. simpl.
          rewrite /Source.find_procedure.
          destruct (procs_map C); last congruence.
          move: wf_e => /andP [] /eqP ? wf_e; subst.
          by rewrite wf_e.
      + pose call_of_event e := if e is ECall _ P _ _ C then Some (C, P) else None.
        have /fsubsetP sub :
          fsubset (called_procedures (procedure_of_trace C P t))
                  ((C, P) |: fset (pmap call_of_event (project_non_inform (comp_subtrace C t)))).
        {
          rewrite /procedure_of_trace /expr_of_trace /switch.
          simpl. rewrite !fsetU0 !fset0U.
          rewrite fsubUset.
          apply /andP; split.
          - rewrite /init_local_buffer_expr /buffer_size.
            case eq_buf: (prog_buffers C) => [buf|] //=; [| by rewrite !fsetU0 fsub0set].
            generalize dependent 0.
            elim: (unfold_buffer buf).
            + by rewrite /= !fsetU0 fsub0set.
            + move=> v ls IH n /=.
              rewrite !fsetU0 !fset0U fsubUset; apply /andP; split.
              * suff: (called_procedures (buffer_nth C n) = fset0) => [->|].
                now eapply fsub0set.
                clear -wf_buffers.
                rewrite /buffer_nth.
                destruct (prog_buffers C) eqn:Hbuf => //=; last by rewrite fsetU0.
                specialize (wf_buffers Hbuf).
                unfold Buffer.well_formed_buffer in *. clear Hbuf.
                destruct s; simpl in *.
                -- clear wf_buffers; revert n; induction n0.
                   destruct n; simpl; by rewrite fsetU0.
                   destruct n; simpl; first by rewrite fsetU0.
                   rewrite IHn0; eauto.
                -- revert n. clear wf_buffers. induction l.
                   destruct n; simpl; by rewrite fsetU0.
                   destruct n; simpl. destruct a; simpl; by (try rewrite fsetU0); reflexivity.
                   by rewrite IHl.
              * eapply IH.
          - remember (length [seq expr_of_event C P i | i <- comp_subtrace C t]) as n.
            clear Heqn.
            elim: (comp_subtrace C t) n.
            + move=> n //=. eapply fsub0set.
            + move=> e ls //=; rewrite !fsetU0 !fset0U => IH.
              move=> n. rewrite fsubUset.
              apply /andP; split.
              * destruct e; simpl.
                -- rewrite !fset0U !fsetU0 fsetUC.
                   rewrite fset_cons. rewrite fsetUA fsubsetU. reflexivity.
                   apply /orP. left. by rewrite fsubsetxx.
                -- by rewrite !fset0U fsub0set.
                -- destruct v as [| [[[[]]]] |]; rewrite //= !fset0U !fsetU0 fsubsetU //=
                                                         fsubset1 eqxx //=.
                -- rewrite //= !fset0U !fsetU0 fsubsetU //= fsubset1 eqxx //=.
                -- rewrite //= !fset0U !fsetU0 fsubsetU //= fsubset1 eqxx //=.
                -- rewrite //= !fset0U !fsetU0 fsubsetU //= fsubset1 eqxx //=.
                -- rewrite //= !fset0U !fsetU0 fsubsetU //= fsubset1 eqxx //=.
                -- rewrite //= !fset0U !fsetU0 fsubsetU //= fsubset1 eqxx //=.
              * destruct e; simpl; try now apply IH.
                rewrite fset_cons.
                rewrite fsetUC -fsetUA fsubsetU. reflexivity.
                apply /orP. right. rewrite fsetUC. eauto.
        }
        move: sub.
        simpl. rewrite !fsetU0 !fset0U => sub.
        move=> C' P' /sub/fsetU1P [[-> ->]|] {sub}.
        * rewrite eqxx. by rewrite Hfind.
        * rewrite in_fset /= => C'_P'.
          subst call_of_event.
          unfold program_of_trace in *.
          specialize (well_formed_events_procs_procedures_of_trace Ht Hprocs_map)
            as Ht_procs_map. 

          assert (Ht': all (well_formed_event intf procs_map) (comp_subtrace C t)).
          {
            clear -Ht_procs_map.
            induction t; auto. simpl in Ht_procs_map.
            move : Ht_procs_map => /andP [[G1 G2]].
            specialize (IHt G2).
            simpl in *.
            find_if_inside_goal; auto. simpl in *. by rewrite G1 IHt.
          }
          assert (Ht'': all (fun e => cur_comp_of_event e == C) (comp_subtrace C t)).
          { clear -Ht.
            elim: t Ht => //= e t IH /andP [] wf /IH all_eq.
            case: ifP=> /eqP eq //=. subst C. by apply /andP. }
          elim: {P intf_C Hfind} (comp_subtrace C t) C'_P' Ht' Ht'' => [| e t' IH] //=.
          destruct e; try by apply IH.
          rewrite inE => /orP [].
          -- move=> /eqP [] ? ?; subst.
             move=> /andP [] /andP [] /eqP i_i1 imported all_wf /andP [] /eqP ? all_C.
             subst. Locate "==".
             case: ifP => //= /eqP ?; subst; auto.
             now apply imported_procedure_iff.
          -- move=> /IH IH' /andP [] /andP i_i1 all_wf /andP [] /eqP ? all_C.
             eapply IH'. eauto. eauto.
          -- move=> //= /IH IH' /andP [] i_i1 all_wf /andP [] /eqP ? all_C. subst.
             eapply IH'. eauto. eauto.
          -- move=> //= /IH IH' /andP [] i_i1 all_wf /andP [] /eqP ? all_C. subst.
             eapply IH'. eauto. eauto.
          -- move=> //= /IH IH' all_wf /andP [] /eqP ? all_C. subst.
             eapply IH'. eauto. eauto.
          -- move=> //= /IH IH' all_wf /andP [] /eqP ? all_C. subst.
             eapply IH'. eauto. eauto.
          -- move=> //= /IH IH' all_wf /andP [] /eqP ? all_C. subst.
             eapply IH'. eauto. eauto.
          -- move=> //= /IH IH' all_wf /andP [] /eqP ? all_C. subst.
             eapply IH'. eauto. eauto.
          -- move=> //= /IH IH' all_wf /andP [] /eqP ? all_C. subst.
             eapply IH'. eauto. eauto.
    - by rewrite domm_map.
    - move=> C; rewrite -mem_domm => /dommP [CI C_CI].
      split.
      + rewrite /Source.has_required_local_buffers. eexists.
        * rewrite mapmE C_CI. reflexivity.
        * simpl. lia.
      + by rewrite /Buffer.well_formed_buffer_opt mapmE C_CI.
    - rewrite /Source.prog_main //=. split; intros H.
      + by erewrite find_procedures_of_trace_main; eauto.
      + erewrite <- domm_exported_procedures_of_trace_interface,
          <-Hdomm, <-Hprocs_map_domm.
        unfold Source.find_procedure in *. apply/dommP.
        destruct (procs_map Component.main) eqn:G; [|discriminate]. by eauto.
  Qed.

  Print Assumptions well_formed_events_well_formed_program.
  
  Lemma closed_program_of_trace t p:
    program_of_trace t = Some p ->
    Source.closed_program p.
  Proof.
    unfold program_of_trace.
    destruct (procedures_of_trace t) eqn:ept; [|discriminate]; intros H; inversion H.
    split=> //=.
    - rewrite /Source.prog_main. simpl. erewrite find_procedures_of_trace_main; eauto.
  Qed.
  
  Arguments Memory.load  : simpl nomatch.
  Arguments Memory.store : simpl nomatch.

  Section WithTrace. (* RB: NOTE: Renaming *)

    Variable t : trace event_inform.
    (* NOTE: need assumption of goodness of the trace *)
    (* Variable good_t: good_trace_extensional (left_addr_good_for_shifting (uniform_shift 1)) (project_non_inform t). *)

    Variable T : Type.
    Variable t_procs : NMap (NMap T). (* Code-independent *)
    Hypothesis domm_t_procs : domm t_procs = domm intf.
    Hypothesis wf_events : all (well_formed_event intf t_procs) t.

    Variable p_interm : Machine.Intermediate.program.
    Hypothesis p_gens_t_inform: exists s,
        Star (CS.CS.sem_inform p_interm) (CS.CS.initial_machine_state p_interm) t s.
    Lemma p_gens_t: exists s, CSInvariants.CSInvariants.is_prefix s p_interm (project_non_inform t).
    Proof.
      destruct p_gens_t_inform as [s star].
      exists s. now apply CS.CS.star_sem_inform_star_sem_non_inform in star.
    Qed.
    (* Hypothesis p_gens_t : exists s, CSInvariants.CSInvariants.is_prefix s p_interm (project_non_inform t). *)

    (* Let t    :=  *)
    (* [DynShare]: This should be the projection of t_inform.
       This projection function may be defined in the Intermedicate/CS.v *)

    Variable p : Source.program.
    Hypothesis Hprog_of_trace : program_of_trace t = Some p.
    
    (**********
     Let p    := program_of_trace t.
     *********)
    
    Let init := Source.prepare_buffers p.

    Local Definition component_buffer C := C \in domm intf.

    Hypothesis wf_p_interm: Machine.Intermediate.well_formed_program p_interm.
    Hypothesis closed_p_interm: Machine.Intermediate.closed_program p_interm.
    Hypothesis p_interm_intf: Machine.Intermediate.prog_interface p_interm = intf.

    Lemma domm_t_procs_exported_procedures_of_trace:
      domm t_procs = domm (exported_procedures_of_trace t).
    Proof. by rewrite domm_exported_procedures_of_trace_interface. Qed.
    
    Lemma valid_procedure_has_block C P :
      valid_procedure C P t ->
      component_buffer C.
    Proof.
      case=> [[-> _ {C P}]|[CI|in_trace]]; rewrite /component_buffer /=.
      by rewrite mem_domm.
      rewrite /Program.has_component /Component.is_exporting /=.
      destruct CI as [? [? ?]]. apply /dommP. eexists; eauto.
      move: in_trace.
      elim: t wf_events.
      - by [].
      - move=> e ls IH /andP [] e_wf ls_wf.
        rewrite /procedure_ids_of_trace
                /procedure_ids_of_subtrace
                /comp_subtrace //.
        destruct (C == cur_comp_of_event e) eqn:curC.
        + simpl. rewrite curC.
          case: e curC e_wf => //=; try (rewrite fset0U; intros; eapply IH; eauto).
          move=> C' [z | [[[perm ?] ?] ?] |] ? ? ? curC e_wf;
                 try (rewrite fset0U; intros; eapply IH; eauto).
          destruct perm;
            try (rewrite fset0U; intros; eapply IH; eauto).
          rewrite in_fsetU1 => /orP [in_C|]; [|by eapply IH].
          move: curC => /eqP curC; subst C'; move: e_wf => //=.
          rewrite <- domm_t_procs.
          destruct (t_procs C) eqn:t_procs_C; last discriminate.
          move=> _. apply /dommP. eexists; eassumption.
        + simpl; rewrite curC.
          eapply IH. eauto.
    Qed.

    Local Definition counter_value C prefix :=
      Z.of_nat (length (comp_subtrace C prefix)).

    (* RB: NOTE: We could make this stronger by noting which component is being
       executed, as this is the only one that can change its own metadata. *)
    Definition well_formed_memory_snapshot_steadystate_shift
               (mem_snapshot mem : Memory.t) (C: Component.id) : Prop :=
      forall b,
        b <> Block.local ->
        memory_shifts_memory_at_shared_addr
          (uniform_shift 1) all_zeros_shift (C, b) mem mem_snapshot.

    Definition well_formed_memory_snapshot_steadystate_block
               (mem_snapshot mem : Memory.t) (C: Component.id) : Prop :=
      forall next,
        Memory.next_block mem_snapshot C = Some next ->
        Memory.next_block mem C = Some (S next).

    Record well_formed_memory_snapshot_steadystate
           (mem_snapshot mem : Memory.t) (C: Component.id) : Prop := {
        steadysnap_shift :
        well_formed_memory_snapshot_steadystate_shift mem_snapshot mem C;
        steadysnap_block :
        well_formed_memory_snapshot_steadystate_block mem_snapshot mem C
      }.

    (* NOTE: Memory.next_block can simplify parts of this *)
    Definition well_formed_memory_snapshot_uninitialized
               (mem_snapshot mem : Memory.t) (C: Component.id) : Prop :=
      
      (exists compMem buf,
          mem_snapshot C = Some compMem /\
            prog_buffers C = Some buf /\
            ComponentMemory.next_block compMem = 1 /\
            compMem = ComponentMemory.prealloc (mkfmap [(Block.local, buf)])
      )
      /\
        (exists src_compMem,
            mem C = Some src_compMem /\
              ComponentMemory.next_block src_compMem = LOCALBUF_blockid
        ).
    

    (* JT: NOTE: The reason this lemma should hold is that the store is to the
       local block [Block.local], which should always be *private memory* (from
       the goodness of the trace) and as a result isn't recorded on the memory
       snapshot. *)
    Lemma metadata_store_preserves_snapshot_shift mem_snapshot mem Pm C Csteady o v mem' :
      well_formed_memory_snapshot_steadystate_shift mem_snapshot mem Csteady ->
      Memory.store mem (Pm, C, Block.local, o) v = Some mem' ->
      well_formed_memory_snapshot_steadystate_shift mem_snapshot mem' Csteady.
    Proof.
      move=> WFMS STORE b Hnot.
      case: (WFMS b); auto.
      rewrite /memory_shifts_memory_at_shared_addr
              /memory_renames_memory_at_shared_addr
              => Cbren [eCbren [WFMS1 WFMS2]].
      unfold sigma_shifting_wrap_bid_in_addr, sigma_shifting_lefttoright_addr_bid
        in *.
      destruct (sigma_shifting_lefttoright_option
                  (uniform_shift 1 Csteady)
                  (all_zeros_shift Csteady) b) as [b'|] eqn:eb'; last discriminate.
      exists (Csteady, b'). split; first reflexivity.
      inversion eCbren; subst; clear eCbren.
      split; intros ? ? Hload; simpl in *.
      - assert (Pointer.eq (Pm, C, Block.local, o)
                           (Permission.data, Csteady, b, offset) = false
               ) as Hneq.
        {
          simpl. destruct (Pm); first by auto. simpl.
          destruct (b =? Block.local) eqn:e; first by apply beq_nat_true in e.
          destruct b; first by auto.
          by rewrite !andbF !andFb.
        }
        move : Hneq => /Pointer.eqP => Hneq.
        specialize (Memory.load_after_store_neq _ _ _ _ _ Hneq STORE) as rewr.
        rewrite rewr in Hload.
        by specialize (WFMS1 _ _ Hload).
      - specialize (WFMS2 _ _ Hload) as [v'' [Hv''1 Hv''2]].
        exists v''. split; last assumption.
        assert (Pointer.eq (Pm, C, Block.local, o)
                           (Permission.data, Csteady, b, offset) = false
               ) as Hneq.
        {
          simpl. destruct (Pm); first by auto. simpl.
          destruct (b =? Block.local) eqn:e; first by apply beq_nat_true in e.
          destruct b; first by auto.
          by rewrite !andbF !andFb.
        }
        move : Hneq => /Pointer.eqP => Hneq.
        specialize (Memory.load_after_store_neq _ _ _ _ _ Hneq STORE) as rewr.
        by rewrite rewr.
    Qed.

    Lemma metadata_store_preserves_snapshot_block mem_snapshot mem Pm C Csteady o v mem' :
      well_formed_memory_snapshot_steadystate_block mem_snapshot mem Csteady ->
      Memory.store mem (Pm, C, Block.local, o) v = Some mem' ->
      well_formed_memory_snapshot_steadystate_block mem_snapshot mem' Csteady.
    Proof.
      move=> WFNB STORE b NEXT.
      specialize (WFNB b NEXT).
      unfold Memory.next_block in *.
      rewrite -WFNB.
      Local Transparent Memory.store.
      unfold Memory.store in STORE.
      Local Opaque Memory.store.
      destruct (Permission.eqb (Pointer.permission (Pm, C, Block.local, o))
                               Permission.data) eqn:PERM;
        last discriminate.
      simpl in STORE.
      destruct (mem C) as [memC |] eqn:MEMC; last discriminate.
      destruct (mem Csteady) as [memCsteady |] eqn:MEMCST; last discriminate.
      injection WFNB as WFNB.
      destruct (mem_snapshot Csteady) as [memsCsteady |] eqn:MEMSCST; last discriminate.
      destruct (ComponentMemory.store memC Block.local o v) eqn:CSTORE;
        last discriminate.
      injection NEXT as ?; subst b.
      apply ComponentMemory.next_block_store_stable in CSTORE.
      injection STORE as ?; subst mem'.
      rewrite setmE.
      destruct (Nat.eqb_spec Csteady C) as [|NEQ].
      - subst Csteady. rewrite eqxx. congruence.
      - move:NEQ => /eqP. rewrite /negb => NEQ.
        destruct (Csteady == C) eqn:NEQ'; first discriminate.
        by rewrite NEQ' MEMCST //.
    Qed.

    Lemma metadata_store_preserves_snapshot mem_snapshot mem Pm C Csteady o v mem' :
      well_formed_memory_snapshot_steadystate mem_snapshot mem Csteady ->
      Memory.store mem (Pm, C, Block.local, o) v = Some mem' ->
      well_formed_memory_snapshot_steadystate mem_snapshot mem' Csteady.
    Proof.
      move=> [WFMS WFNB] STORE. split.
      - eapply metadata_store_preserves_snapshot_shift; eassumption.
      - eapply metadata_store_preserves_snapshot_block; eassumption.
    Qed.

    Definition postcondition_event_snapshot_steadystate
               (e: event_inform) (mem: Memory.t) (C: Component.id) : Prop :=
      let mem_snapshot := mem_of_event_inform e in
      well_formed_memory_snapshot_steadystate mem_snapshot mem C.

    Definition postcondition_event_snapshot_uninitialized
               (e: event_inform) (mem: Memory.t) (C: Component.id) : Prop :=
      let mem_snapshot := mem_of_event_inform e in
      well_formed_memory_snapshot_uninitialized mem_snapshot mem C.

    (* NOTE: Seems to talk about the memory /before/ executing the event. Prerequisite
     to do the event *)
    Definition precondition_event_intermediate (e: event_inform) (mem: Memory.t): Prop :=
      match e with
      | ECallInform Csrc _ arg _ _ _ =>
          Memory.load mem (Permission.data, Csrc, Block.local, reg_offset E_R_COM)
          = Some arg
      | ERetInform Csrc ret _ _ _ =>
          Memory.load mem (Permission.data, Csrc, Block.local, reg_offset E_R_COM)
          = Some ret
      | EAlloc C _ rsize _ _ =>
          exists size,
          (size > 0)%Z /\
            Memory.load mem (Permission.data, C, Block.local, (reg_offset rsize)) =
              Some (Int size)
      (* TODO: May have to add new well-formedness conditions for other events *)
      | _ => True
      end.

    (* AEK: TODO: This definition should be moved to Common/TracesInform.v, right? *)
    (* The reason I think it should be moved is that we will need a lemma that     *)
    (* tells us that an Intermediate trace satisfies this definition.              *)

    (* Notice that the "from" state (consisting of a Register.t and a Memory.t)    *)
    (* is implicitly given by the first parameter, which is an event_inform.       *)
    (* The second and the third parameters represent the "to" state.               *)
    Inductive event_step_from_regfile_mem : Machine.Intermediate.Register.t ->
                                            Memory.t ->
                                            (* Register file and memory BEFORE
                                               event-producing step *)
                                            event_inform ->
                                            Prop :=
    | step_ECallInform:
      forall C P call_arg mem regs regs' C',
        C <> C' ->
        imported_procedure intf C C' P ->
        Machine.Intermediate.Register.get
          Machine.R_COM
          regs = call_arg ->
        regs' = Machine.Intermediate.Register.invalidate regs ->
        event_step_from_regfile_mem regs mem (ECallInform C P call_arg mem regs' C')
    | step_ERetInform:
      forall mem regs regs' C C' ret_arg,
        C <> C' ->
        Machine.Intermediate.Register.get
          Machine.R_COM
          regs = ret_arg ->
        regs' = Machine.Intermediate.Register.invalidate regs ->
        event_step_from_regfile_mem regs mem (ERetInform C ret_arg mem regs' C')
    | step_EConst:
      forall mem regs regs' C er v,
        regs' = Machine.Intermediate.Register.set
                  (Ereg_to_reg er)
                  v
                  regs ->
        event_step_from_regfile_mem regs mem (EConst C v er mem regs')
    | step_EMov:
      forall mem regs regs' C ersrc erdest,
        regs' = Machine.Intermediate.Register.set (Ereg_to_reg erdest)
                                                  (Machine.Intermediate.Register.get
                                                     (Ereg_to_reg ersrc) regs)
                                                  regs ->
        event_step_from_regfile_mem regs mem (EMov C ersrc erdest mem regs')
    | step_EBinop:
      forall result eop mem regs regs' C er1 er2 er3,
        result = eval_binop
                   (Ebinop_to_binop eop)
                   (Machine.Intermediate.Register.get (Ereg_to_reg er1) regs)
                   (Machine.Intermediate.Register.get (Ereg_to_reg er2) regs) ->
        regs' = Machine.Intermediate.Register.set (Ereg_to_reg er3)
                                                  result
                                                  regs ->
        event_step_from_regfile_mem regs mem (EBinop C eop er1 er2 er3 mem regs')
    | step_ELoad:
      forall mem regs regs' C er1 er2 ptr v,
        Machine.Intermediate.Register.get
          (Ereg_to_reg er1)
          regs = Ptr ptr ->
        Memory.load mem ptr = Some v ->
        Machine.Intermediate.Register.set
          (Ereg_to_reg er2)
          v regs = regs' ->
        event_step_from_regfile_mem regs mem (ELoad C er1 er2 mem regs')
    | step_EStore:
      forall mem mem' regs C ptr er1 er2,
        Machine.Intermediate.Register.get
          (Ereg_to_reg er1)
          regs = Ptr ptr ->
        Memory.store
          mem
          ptr
          (Machine.Intermediate.Register.get
             (Ereg_to_reg er2)
             regs)
        = Some mem' ->
        event_step_from_regfile_mem regs mem (EStore C er1 er2 mem' regs)
    | step_EAlloc:
      forall mem mem' regs regs' C ersize erptr size ptr,
        Machine.Intermediate.Register.get
          (Ereg_to_reg ersize)
          regs = Int size ->
        (size > 0) % Z ->
        Memory.alloc mem C (Z.to_nat size) = Some (mem', ptr) ->
        regs' =
          Machine.Intermediate.Register.set
            (Ereg_to_reg erptr)
            (Ptr ptr)
            regs ->
        event_step_from_regfile_mem regs mem (EAlloc C erptr ersize mem' regs').

    Let initial_memory :=
          mkfmapf
            (fun C => ComponentMemory.prealloc
                        (match prog_buffers C with
                         | Some buf => mkfmap [(Block.local, buf)]
                         | None => emptym
                         end))
            (domm intf).

    Inductive prefix_star_event_steps : (* Machine.Intermediate.Register.t -> *)
      (* Memory.t -> *)
      trace event_inform -> Prop :=
    | nil_star_event_steps:
      prefix_star_event_steps E0
    (* Machine.Intermediate.Register.init *)
    (* (Source.prepare_buffers p) *)
    (* E0 *)
    (* AEK: Will prepare_buffers match the Intermediate prepare buffer function? *)
    | singleton_star_event_steps:
      forall e,
        event_step_from_regfile_mem
          (Machine.Intermediate.Register.set
             Machine.R_COM (Int 0)
             Machine.Intermediate.Register.init)
          initial_memory
          e ->
        prefix_star_event_steps [:: e]
    | rcons_star_event_steps:
      forall prefix e e',
        prefix_star_event_steps (rcons prefix e) ->
        event_step_from_regfile_mem (register_file_of_event_inform e) (mem_of_event_inform e) e' ->
        prefix_star_event_steps (rcons (rcons prefix e) e').

    Inductive trace_event_components : trace event_inform -> Prop :=
    | evcomps_nil : trace_event_components E0
    | evcomps_event e : trace_event_components [e]
    | evcomps_rcons e1 e2 t :
      next_comp_of_event e1 = cur_comp_of_event e2 ->
      trace_event_components (rcons t e1) ->
      trace_event_components (rcons (rcons t e1) e2).

    Record well_formed_intermediate_prefix (pref: trace event_inform) : Prop :=
      {
        ipref_evsteps : prefix_star_event_steps pref;
        ipref_evcomps : trace_event_components pref
      }.

    Lemma trace_event_components_app_l t1 t2:
      trace_event_components (t1 ++ t2) ->
      trace_event_components t1.
    Proof.
      induction t2 as [| t2 e IHt2] using last_ind; intros H.
      - by setoid_rewrite app_nil_r in H.
      - setoid_rewrite <- cats1 in H. setoid_rewrite app_assoc in H.
        setoid_rewrite cats1 in H. apply IHt2.
        inversion H; [unfold E0 in *; find_nil_rcons | |].
        + remember ((t1 ++ t2)%list) as t12.
          assert (t12 = nil).
          {
            destruct t12; auto. rewrite rcons_cons in H1.
            inversion H1. by find_nil_rcons.
          }
          subst. rewrite H0 in H1. simpl in *.
          apply app_eq_nil in H0 as [G G']; subst. by constructor.
        + find_rcons_rcons.
          by setoid_rewrite <- H4.
    Qed.

    Lemma trace_event_components_app_r t1 t2:
      trace_event_components (t1 ++ t2) ->
      trace_event_components t2.
    Proof.
      induction t2 as [| t2 e IHt2] using last_ind; intros H.
      - by constructor.
      - destruct t2 using last_ind; simpl.
        + by constructor.
        + clear IHt0. inversion H; unfold E0 in *.
          * symmetry in H1. apply app_eq_nil in H1 as [? ?]. by rewrite H1; constructor.
          * rewrite -rcons_cat in H1.
            setoid_rewrite <- app_nil_l in H1 at 1. setoid_rewrite cats1 in H1.
            find_rcons_rcons.
            symmetry in H2. apply app_eq_nil in H2 as [? ?]. by find_nil_rcons.
          * rewrite -rcons_cat in H0. find_rcons_rcons.
            rewrite -rcons_cat in H4. find_rcons_rcons.
            constructor; auto. apply IHt2; by rewrite -rcons_cat.
    Qed.

    Lemma well_formed_intermediate_prefix_inv:
      forall prefix suffix,
        well_formed_intermediate_prefix (prefix ++ suffix) ->
        well_formed_intermediate_prefix prefix.
    Proof.
      move=> prefix suffix.
      elim: suffix prefix => [prefix | a l IH].
      - by rewrite cats0.
      - move=> prefix.
        rewrite -cat_rcons => /IH IH'.
        split.
        + destruct IH' as [IH' _].
          inversion IH'.
          * now destruct prefix.
          * have: (e = a /\ prefix = nil).
            { destruct prefix. inversion H; split; congruence.
              inversion H. now destruct prefix. }
            move=> [] ? ?; subst. constructor.
          * eapply rcons_inj in H. inversion H; subst; clear H.
            inversion IH'; subst; clear IH'.
            -- now destruct prefix0.
            -- now destruct prefix0.
            -- eauto.
        + destruct IH' as [_ IH'].
          rewrite -cats1 in IH'.
          by eapply trace_event_components_app_l; eauto.
    Qed.

    (* AEK: Now not sure whether this definition should be called a postcondition.   *)
    (* The reason I am not sure is that the r that we are projecting out of an event *)
    (* e is NOT the register file *after* executing e. It is the register file       *)
    (* *before* executing e.                                                         *)
    Definition postcondition_event_registers (e: event_inform) (mem: Memory.t): Prop :=
      let regs := register_file_of_event_inform e in
      forall reg n,
        reg_offset (reg_to_Ereg reg) = n ->
        exists v v',
          Memory.load mem (Permission.data, next_comp_of_event e, Block.local, n) = Some v  /\
            shift_value_option (uniform_shift 1) all_zeros_shift v = Some v' /\
            Machine.Intermediate.Register.get reg regs = v'.


    Definition postcondition_event_registers_ini (C: Component.id) (mem: Memory.t): Prop :=
      (forall (R: Machine.register) (n: Z),
          R <> Machine.R_COM ->
          reg_offset (reg_to_Ereg R) = n ->
          Memory.load mem (Permission.data, C, Block.local, n) = Some Undef)
      /\
        Memory.load mem (Permission.data, C, Block.local, reg_offset E_R_COM) = Some (Int 0).

    Lemma postcondition_event_registers_load C mem reg:
      postcondition_event_registers_ini C mem ->
      exists v,
        Memory.load mem (Permission.data, C, Block.local, reg_offset reg) = Some v /\
          (v = Int 0 \/ v = Undef).
    Proof.
      intros [Hothers HRCOM]. specialize (Hothers (Ereg_to_reg reg)).
      destruct reg;
        try (eexists; split; [| by auto];
             apply Hothers; [simpl; discriminate | reflexivity]).
      now eauto.
    Qed.

    Definition postcondition_steady_state
               (e: event_inform) (mem: Memory.t) (C: Component.id) :=
      Memory.load mem (Permission.data, C, Block.local, INITFLAG_offset) =
        Some (Int 1%Z)
      /\
        Memory.load mem (Permission.data, C, Block.local, LOCALBUF_offset) =
          Some (Ptr (Permission.data, C, LOCALBUF_blockid, 0%Z))
      /\
        postcondition_event_snapshot_steadystate e mem C.

    Definition postcondition_uninitialized
               (t: trace event_inform) (e: event_inform) (mem: Memory.t) (C: Component.id) :=
      Memory.load mem (Permission.data, C, Block.local, INITFLAG_offset) =
        Some (Int 0%Z)
      /\
        Memory.load mem (Permission.data, C, Block.local, LOCALBUF_offset) = Some Undef
      /\
        postcondition_event_snapshot_uninitialized e mem C
      /\
        (forall b, ~ addr_shared_so_far (C, b) (project_non_inform (rcons t e))).

    Record well_formed_memory (prefix: trace event_inform) (mem: Memory.t) : Prop :=
      {
        wfmem_counter:
        forall C,
          component_buffer C ->
          Memory.load mem (Permission.data, C, Block.local, 0%Z) =
            Some (Int (counter_value C prefix));
        wfmem_extcall_ini:
        prefix = [] ->
        (forall C,
            component_buffer C ->
            C = Component.main ->
            Memory.load mem (Permission.data, C, Block.local, EXTCALL_offset) =
              Some (Int 0%Z)) /\
          (forall C,
              component_buffer C ->
              C <> Component.main ->
              Memory.load mem (Permission.data, C, Block.local, EXTCALL_offset) =
                Some (Int 1%Z));
        wfmem_extcall:
        forall prefix' e,
          prefix = prefix' ++ [:: e] ->
          (forall C,
              component_buffer C ->
              C = next_comp_of_event e ->
              Memory.load mem (Permission.data, C, Block.local, EXTCALL_offset) =
                Some (Int 0%Z)) /\
            (forall C,
                component_buffer C ->
                C <> next_comp_of_event e ->
                Memory.load mem (Permission.data, C, Block.local, EXTCALL_offset) =
                  Some (Int 1%Z));
        (* NOTE: Might be redundant? *)
        wfmem_meta:
        forall C r,
          component_buffer C ->
          exists v,
            Memory.load mem (Permission.data, C, Block.local, reg_offset r) = Some v;
        wfmem_ini: forall C,
          prefix = [] ->
          component_buffer C ->
          postcondition_event_registers_ini C mem
          /\
            (C <> Component.main ->
             (Memory.load mem (Permission.data, C, Block.local, INITFLAG_offset) =
                Some (Int 0%Z)
              /\
                Memory.load mem (Permission.data, C, Block.local, LOCALBUF_offset) =
                  Some Undef
              /\
                Memory.next_block mem C = Some LOCALBUF_blockid
              /\
                well_formed_memory_snapshot_uninitialized initial_memory mem C))
          /\
            (C = Component.main ->
             (Memory.load mem (Permission.data, C, Block.local, INITFLAG_offset) =
                Some (Int 1%Z)
              /\
                Memory.load mem (Permission.data, C, Block.local, LOCALBUF_offset) =
                  Some (Ptr (Permission.data, C, LOCALBUF_blockid, 0%Z))
              /\
                well_formed_memory_snapshot_steadystate initial_memory mem C)) ;
        wfmem: forall prefix' e,
          prefix = prefix' ++ [:: e] ->
          postcondition_event_registers e mem
          /\
            (forall C,
                component_buffer C ->
                C = next_comp_of_event e ->
                postcondition_steady_state e mem C) /\
            (forall C,
                component_buffer C ->
                C <> next_comp_of_event e ->
                (
                  postcondition_steady_state e mem C
                  \/
                    postcondition_uninitialized prefix' e mem C
                )
            );
        wfmem_no_private_ptr:
        forall ptr C b o,
          Memory.load mem ptr = Some (Ptr (Permission.data, C, b, o)) ->
          b <> Block.local;
      }.

    Lemma counter_value_snoc prefix C e :
      counter_value C (prefix ++ [e])
      = (counter_value C prefix
         + if C == cur_comp_of_event e then 1 else 0) % Z.
    Proof.
      unfold counter_value, comp_subtrace.
      rewrite filter_cat app_length. simpl.
      rewrite Nat2Z.inj_add.
      now destruct (_ == _).
    Qed.

    (* RB: TODO: Relocate, replace existing but less general
       [rcons_trace_event_eq_inversion] with second lemma. *)
    Lemma size_inj :
      forall {A} (l1 l2 : list A), l1 = l2 -> size l1 = size l2.
    Proof.
      intros A l1 l2 Heq; subst l2. reflexivity.
    Qed.

    Lemma rcons_inv :
      forall {A} (l1 l2 : list A) e1 e2,
        l1 ++ [e1] = l2 ++ [e2] ->
        l1 = l2 /\ e1 = e2.
    Proof.
      intros A l1.
      induction l1 as [| e l1' IHl1'];
        simpl;
        intros l2 e1 e2 Heq.
      - destruct l2 as [| e' l2'].
        + injection Heq as Heq; subst e2.
          split; reflexivity.
        + inversion Heq as [[Heq1 Heq2]]; subst.
          apply size_inj in Heq2.
          rewrite cats1 size_rcons in Heq2.
          discriminate.
      - destruct l2 as [| e' l2'].
        + inversion Heq as [[Heq1 Heq2]]; subst e2.
          apply size_inj in Heq2.
          rewrite cats1 size_rcons in Heq2.
          discriminate.
        + injection Heq as ? Heq; subst e'.
          specialize (IHl1' l2' e1 e2 Heq) as [? ?]; subst e2 l2'.
          split; reflexivity.
    Qed.

    Lemma well_formed_memory_store_reg_offset prefix mem C r v :
      component_buffer C ->
      well_formed_memory prefix mem ->
      exists mem',
        Memory.store mem (Permission.data, C, Block.local, reg_offset r) v = Some mem'.
    Proof.
      intros C_b wf_mem.
      specialize ((wfmem_meta wf_mem) _ r C_b) as [v' Hload].
      eapply Memory.store_after_load.
      exact Hload.
    Qed.

    Variant well_formed_state (stk_st: stack_state)
            (prefix suffix: trace event_inform) : CS.state -> Prop :=
      | WellFormedState C procs stk mem k exp arg P
                        of C = cur_comp stk_st
        &  k = Kstop
        &  exp = procedure_of_trace C P t
        &  well_bracketed_trace stk_st suffix
        &  all (@well_formed_event T intf procs) suffix
        &  well_formed_stack stk_st stk mem t
        &  well_formed_memory prefix mem
        &  valid_procedure C P t
        :  well_formed_state stk_st prefix suffix [CState C, stk, mem, k, exp, arg].

    (* [DynShare] Rephrase state well-formedness invariants in terms of reverse
     executions. This version still preserves the intermediate stack state.
     TODO: This part needs to be trimmed down, and naming conventions
     homogenized. *)
    Variant well_formed_state_r (stk_st: stack_state)
            (prefix suffix: trace event_inform) : CS.state -> Prop :=
      | WellFormedStateR C procs stk mem k exp arg P
                         of C = cur_comp stk_st
        &  k = Kstop
        (* &  exp = procedure_of_trace C P t *)
        &  exp = expr_of_trace C P (comp_subtrace C t)
        &  well_bracketed_trace stk_st suffix
        &  all (@well_formed_event T intf procs) suffix
        &  well_formed_stack stk_st stk mem t
        &  well_formed_memory prefix mem
        &  valid_procedure C P t
        :  well_formed_state_r stk_st prefix suffix [CState C, stk, mem, k, exp, arg].

    (* [DynShare] This second version of the right-to-left invariant does away
     with the stack state and effects further simplifications. Some bits,
     especially those that describe the memory, need to be fixed and restored.
     Note that, while this is still phrased in terms of a [suffix], this is
     actually meant to represent a whole trace, e.g., [t]. (However, this could
     make it tricky to compose partial invariants.) *)
    Variant well_formed_state_right (* stk_st: stack_state *)
            (suffix: trace event_inform) : CS.state -> Prop :=
      | WellFormedStateRight C procs stk mem k exp arg P
                             of
                             (* C = cur_comp stk_s & *)
                             k = Kstop
        &  exp = procedure_of_trace C P t
        &  TracesInform.well_bracketed_trace_r suffix
        &  all (@well_formed_event T intf procs) suffix
        (* &  well_formed_stack stk_st stk *)
        (* &  well_formed_memory prefix mem *) (* FIXME *)
        &  valid_procedure C P t
        :  well_formed_state_right (* stk_st *) suffix [CState C, stk, mem, k, exp, arg].

    (* NOTE: Do we need/want to split off memory invariants, etc., so that they
     hold at every step? *)

    (* [DynShare] We will probably need a variant of well formedness that is defined
     on non-informative traces as well. *)

    (* Could be used to obtain a more general result; currently this should
       not be necessary. *)
    (* Variable metadata_size_lhs: Component.id -> nat. *)

    (* NOTE: Could we dispense with complex well-formed states by looking only
       at well-formedness of traces?

    Definition well_formed_prefix_suffix
               (prefix suffix : trace event_inform) : Prop.
    Admitted.

    Definition well_formed_trace (t : trace event_inform) : Prop :=
      forall prefix suffix,
        t = prefix ++ suffix ->
        well_formed_prefix_suffix prefix suffix.

    Lemma definability_gen_rel t_inform cs :
      well_formed_trace t_inform ->
      CS.initial_state p cs ->
    exists cs' t_noninform const_map,
      Star (CS.sem p) cs t_noninform cs' /\
      traces_shift_each_other metadata_size_lhs const_map (project_non_inform t_inform) t_noninform /\
      CS.final_state cs'.

       The point is that this is essentially the final definability lemma. The
       predictable challenges would reappear in its proof:
         - Would need to state a similar lemma without depending on an initial
           state (unless inducting "on the right"?).
         - Well-bracketedness would fail in the inductive case.

       The possible solutions involve some kind of decomposition of the trace
       into prefix and suffix, or directly relying on AAA's method.

       In any case, well-bracketedness is important for the proof *)


    Remark reg_offset0 r : reg_offset r <> 0%Z.
    Proof.
      destruct r; discriminate.
    Qed.

    Remark pointer_reg_offset0
           (P : Permission.id) (C : Component.id) (b : Block.id) r :
      (P, C, b, reg_offset r) <> (P, C, b, 0%Z).
    Proof.
      injection. apply reg_offset0.
    Qed.

    Lemma shift_S_Some C b :
      sigma_shifting_wrap_bid_in_addr
        (sigma_shifting_lefttoright_addr_bid (uniform_shift 1) all_zeros_shift)
        (C, S b) = Some (C, b).
    Proof.
      rewrite /sigma_shifting_wrap_bid_in_addr
              /sigma_shifting_lefttoright_addr_bid
              /sigma_shifting_lefttoright_option
              /all_zeros_shift /uniform_shift
              /ssrnat.leq
              /ssrnat.addn /ssrnat.addn_rec
              /ssrnat.subn /ssrnat.subn_rec
              /=
              Nat.add_0_r Nat.sub_0_r.
      reflexivity.
    Qed.

    (* TODO: [DynShare] Trace relation should appear here too!

       Well-bracketedness, etc., probably need to be rewritten to operate "in
       reverse", i.e., adding events at the end of the trace to match the
       definition of the trace relation.

       NOTE: Propositional and not boolean conjunction in the conclusion at the
       moment. *)

    (* Cf. event_non_inform_of_nil_or_singleton *)
    Lemma project_non_inform_singleton e:
      project_non_inform [:: e] = [::] \/
        exists e', project_non_inform [:: e] = [:: e'].
    Proof.
      destruct e; simpl;
        try (now (right; eauto));
        now left.
    Qed.

    Lemma wfmem_postcondition_initial_preserved
          eprev ecur curC (mem' mem0 mem'': Memory.t) tpref:
      (exists s, CSInvariants.CSInvariants.is_prefix s p_interm (project_non_inform (rcons (rcons tpref eprev) ecur))) ->
      mem' = mem_of_event_inform eprev ->
      mem' = mem_of_event_inform ecur ->
      next_comp_of_event eprev = curC ->
      cur_comp_of_event ecur = curC ->
      next_comp_of_event ecur = curC ->
      (forall C : nat_ordType,
          component_buffer C ->
          C <> next_comp_of_event eprev ->
          postcondition_steady_state eprev mem0 C \/
            postcondition_uninitialized tpref eprev mem0 C
      ) ->
      (forall C : Component.id, C <> curC -> mem0 C = mem'' C)
      ->
        forall C : nat_ordType,
          component_buffer C ->
          C <> next_comp_of_event ecur ->
          postcondition_steady_state ecur mem'' C \/
            postcondition_uninitialized (rcons tpref eprev) ecur mem'' C.
    Proof.
      intros [s is_prefix] Hmem' Hmem'2 Hcomp1 Hcomp2 Hcomp3 Hinitial mem0_mem''_asmp.

      assert (mem0_mem'': forall C b o,
                 C <> curC ->
                 Memory.load mem0  (Permission.data, C, b, o) =
                   Memory.load mem'' (Permission.data, C, b, o)).
      { intros ? ? ? HC.
        unfold Memory.load; simpl.
        rewrite mem0_mem''_asmp; by auto. }

      intros C' Hcomp Hnext. subst.
      rewrite Hcomp3 in Hnext.
      specialize (Hinitial _ Hcomp Hnext) as [Hsteady' | Hinitial].
      * destruct Hsteady' as [Hinitflag [Hlocalbuf Hsteady']].
        left. split; [| split].
        -- rewrite -mem0_mem''; by auto.
        -- rewrite -mem0_mem''; by auto.
        -- unfold postcondition_event_snapshot_steadystate
             in *.
           destruct Hsteady' as [Hsteady' Hnextblock].
           split.
           ++ intros b Hlocal.
              specialize (Hsteady' b Hlocal)
                as [Cb [Hshift' [Hrename Hrename']]].
              exists Cb. split; [| split].
              ** exact Hshift'.
              ** intros off v' Hload. simpl in *.
                 rewrite <- mem0_mem'' in Hload; last by auto.
                 specialize (Hrename off v' Hload)
                   as [v'' [Hload'' Hrename]].
                 exists v''. split; congruence.
              ** intros off v' Hload. rewrite -Hmem'2 in Hload.
                 specialize (Hrename' off v' Hload)
                   as [v'' [Hload'' Hrename']].
                 exists v''. split; simpl.
                 --- rewrite <- mem0_mem''; by auto.
                 --- assumption.
           ++ intros b Hnextb.
              unfold Memory.next_block.
              rewrite -(mem0_mem''_asmp _ Hnext).
              apply Hnextblock.
              rewrite Hmem'2.
              assumption.
      * destruct Hinitial
          as [Hinitflag [Hlocalbuf [
                    [[compMem [buf [He1 Hbuf]]]
                       Hinitial2] Hshared
                  ]
          ]].
        right. split; [| split; [| split]].
        -- rewrite -mem0_mem''; by auto.
        -- rewrite -mem0_mem''; by auto. 
        -- unfold postcondition_event_snapshot_uninitialized
             in *.
           split;
             last by rewrite -mem0_mem''_asmp.
           simpl. exists compMem, buf. by rewrite -Hmem'2.
        -- intros b Hcontra.
           (* destruct p_gens_t as [s_p is_prefix]. *)
           destruct (project_non_inform_singleton ecur) as [Hecur0 | [ecur' Hecur1]].
           ++ rewrite -Hcomp2 in Hnext.
              clear -Hcontra Hshared Hnext Hecur0.
              rewrite -!cats1 project_non_inform_append Hecur0 E0_right cats1 in Hcontra.
              now apply (Hshared b).
           ++
             rewrite -!cats1 project_non_inform_append Hecur1 !cats1 in Hcontra.
             unfold Eapp in Hcontra. setoid_rewrite cats1 in Hcontra.
             rewrite -!cats1 project_non_inform_append Hecur1 !cats1 in is_prefix.
             unfold Eapp in is_prefix. setoid_rewrite cats1 in is_prefix.
             rewrite -Hcomp2 in Hnext.
             assert (Hcomp_ecur : cur_comp_of_event ecur = cur_comp_of_event ecur'). {
               destruct ecur; destruct ecur'; inversion Hecur1; reflexivity.
             }
             rewrite Hcomp_ecur in Hnext.
             pose proof CSInvariants.CSInvariants.not_executing_can_not_share
                  _ _ _ _ _ b
                  wf_p_interm closed_p_interm is_prefix Hnext Hshared
               as Hnot_shared.
             contradiction.
    Qed.

    Lemma prepare_buffers_prealloc C :
      (* prog_buffers C = Some buf -> *)
      component_buffer C ->
      Source.prepare_buffers p C = Some (ComponentMemory.prealloc [fmap (0, (inr meta_buffer))]).
    Proof.
      unfold program_of_trace in Hprog_of_trace.
      destruct (procedures_of_trace t) eqn:eprocst; [|discriminate].
      inversion Hprog_of_trace; subst.
      rewrite /Source.prepare_buffers
              mapmE /omap /obind /oapp /=
              mapmE /omap /obind /oapp /=.
      destruct (intf C) as [CI |] eqn:H_CI;
        last (move => /dommP => [[? ?]]; congruence).
      reflexivity.
    Qed.

    (* TODO: Move to language *)
    Lemma next_block_prepare_buffers C :
      component_buffer C ->
      Memory.next_block (Source.prepare_buffers p) C = Some LOCALBUF_blockid.
    Proof.
      unfold program_of_trace in Hprog_of_trace.
      destruct (procedures_of_trace t) eqn:eprocst; [|discriminate].
      inversion Hprog_of_trace.
      rewrite H0.
      rewrite /component_buffer /Memory.next_block /Source.prepare_buffers => C_b.
      rewrite mapmE /omap /obind /oapp. 
      destruct (Source.prog_buffers p C) as [buf |] eqn:Hbuf.
      - simpl. rewrite ComponentMemory.nextblock_prealloc.
        now rewrite domm_set domm0 fsetU0.
      - subst. simpl in Hbuf. 
        rewrite mapmE /omap /obind /oapp in Hbuf.
        move: C_b => /dommP => [[CI H_CI]].
        now rewrite H_CI in Hbuf.
    Qed.

    Lemma next_block_initial_memory C :
      component_buffer C ->
      Memory.next_block initial_memory C = Some 1.
    Proof.
      rewrite /component_buffer /Memory.next_block /initial_memory => C_b.
      rewrite mkfmapfE C_b.
      rewrite ComponentMemory.nextblock_prealloc.
      destruct (prog_buffers C) as [buf |] eqn:Hbuf.
      - now rewrite domm_set domm0 fsetU0.
      - rewrite domm_buffers in C_b.
        move: Hbuf => /dommPn.
        now rewrite C_b.
    Qed.

    (* TODO: Inline idiomatic proof of this. *)
    Remark next_block_prepare_buffers_aux :
      S (fold_left Nat.max [fset Block.local] 0) = 1.
    Proof.
      by rewrite fsetU0.
    Qed.

    (* NOTE: This lemma is easier to use if Z-to-nat conversion is in the RHS,
       and the >= 0 condition is added as a hypothesis to the statement. *)
    Lemma load_prepare_buffers C o :
      component_buffer C ->
      (* (0 <= o)%Z -> *)
      (* Memory.load (Source.prepare_buffers p) (Permission.data, C, Block.local, o) = nth_error meta_buffer (Z.to_nat o). *)
      Memory.load (Source.prepare_buffers p) (Permission.data, C, Block.local, Z.of_nat o) = nth_error meta_buffer o.
    Proof.
      unfold program_of_trace in Hprog_of_trace.
      destruct (procedures_of_trace t) eqn:eprocst; [|discriminate].
      inversion Hprog_of_trace as [Hprog_of_trace'].
      rewrite Hprog_of_trace'.

      rewrite /component_buffer => /dommP [CI Hint].

      subst p.
      rewrite /Memory.load /=
              /Source.prepare_buffers /=
              mapmE /omap /obind /oapp
              mapmE /omap /obind /oapp
              Hint
              ComponentMemory.load_prealloc /=
              /meta_buffer.
      destruct (Z.leb_spec0 0%Z (Z.of_nat o)).
      - by rewrite Nat2Z.id.
      - lia.
    Qed.

    Lemma load_postcondition_steady_state C prefix e mem b o v :
      postcondition_steady_state e mem C \/ postcondition_uninitialized prefix e mem C ->
      Memory.load mem (Permission.data, C, S b, o) = Some v ->
      postcondition_steady_state e mem C.
    Proof.
      intros [Hsteady | Hinitial] Hload.
      - assumption.
      - exfalso.
        destruct Hinitial
          as [Hinitflag [Hlocalbuf [[Hprealloc
                                       [Cmem [HCmem Hblock]]]
                                      Hnot_shared]]].
        assert (Hnextblock : Memory.next_block mem C = Some LOCALBUF_blockid)
          by (by rewrite /Memory.next_block HCmem Hblock).
        erewrite Memory.load_next_block_None in Hload.
        + discriminate.
        + by apply Hnextblock.
        + rewrite /= /LOCALBUF_blockid. apply /ssrnat.leP. lia.
    Qed.

    Ltac ucongruence := autounfold with definabilitydb; congruence.

    Ltac simplify_memory :=
      repeat (
          match goal with
          | H: Memory.store _ ?ptr ?v' = Some ?mem |-
              Memory.load ?mem ?ptr = Some ?v =>
              rewrite (Memory.load_after_store_eq _ _ _ _ H);
              try (simpl; ucongruence);
              eauto
          | H: Memory.store _ ?ptr _ = Some ?mem |-
              Memory.load ?mem ?ptr' = Some _ =>
              rewrite (Memory.load_after_store_neq _ _ _ _ _ _ H);
              try (simpl; ucongruence);
              eauto
          | H: Memory.alloc _ _ _ = Some (?mem, _) |-
              Memory.load ?mem _ = Some _ =>
              erewrite Memory.load_after_alloc;
              eauto;
              try (simpl; ucongruence)
          end).

    (* A restricted version with finer control to start refactoring. *)
    Ltac simplify_memory' :=
      repeat
        match goal with
        | H : Memory.store ?MEM ?PTR ?V = Some ?MEM'
          |- Memory.load ?MEM' ?PTR = Some _
          =>
            erewrite Memory.load_after_store_eq;
            [reflexivity | exact H]
        | H : Memory.store ?MEM ?PTR ?V = Some ?MEM',
            G : Memory.load ?MEM' ?PTR = Some _ |- _
          =>
            erewrite Memory.load_after_store_eq in G;
            [reflexivity | exact H]
        | H : Memory.store ?MEM (_, ?C, ?B, ?O) ?V = Some ?MEM'
          |- Memory.load ?MEM' (_, ?C', ?B', ?O') = ?V'
          =>
            erewrite Memory.load_after_store_neq;
            [| | exact H];
            [| injection;
               (discriminate
                || contradiction
                || congruence
                || match O with
                   | reg_offset ?R =>
                       match O' with
                       | reg_offset ?R' => now (destruct R; destruct R')
                       | _ => now destruct R
                       end
                   | _ =>
                       match O' with
                       | reg_offset ?R' => now destruct R'
                       | _ => fail
                       end
                   end)]
        | H : Memory.store ?MEM (_, ?C, ?B, ?O) ?V = Some ?MEM',
            G : Memory.load ?MEM' (_, ?C', ?B', ?O') = ?V' |- _
          =>
            erewrite Memory.load_after_store_neq in G;
            [| | exact H];
            [| injection;
               (discriminate
                || contradiction
                || congruence
                || match O with
                   | reg_offset ?R =>
                       match O' with
                       | reg_offset ?R' => now (destruct R; destruct R')
                       | _ => now destruct R
                       end
                   | _ =>
                       match O' with
                       | reg_offset ?R' => now destruct R'
                       | _ => fail
                       end
                   end)]
        | H : Memory.alloc ?MEM ?C ?N = Some (?MEM', ?B')
          |- Memory.load ?MEM' (_, ?C', ?B'', ?O') = ?V'
          =>
            erewrite Memory.load_after_alloc;
            [| exact H |];
            [| injection;
               (discriminate
                || contradiction
                || congruence
                || match O with
                   | reg_offset ?R => now destruct R
                   | _ => fail
                   end
                || match O' with
                   | reg_offset ?R => now destruct R
                   | _ => fail
                   end)]
        | H : Memory.alloc ?MEM ?C ?N = Some (?MEM', ?B'),
            G : Memory.load ?MEM' (_, ?C', ?B'', ?O') = ?V' |- _
          =>
            erewrite Memory.load_after_alloc in G;
            [| exact H |];
            [| injection;
               (discriminate
                || contradiction
                || congruence
                || match O with
                   | reg_offset ?R => now destruct R
                   | _ => fail
                   end
                || match O' with
                   | reg_offset ?R => now destruct R
                   | _ => fail
                   end)]
        end.

    (* TODO: Temporary of simplify_memory_init only to avoid conflicts. *)
    Ltac simplify_memory_init' H:=
      simplify_memory; rewrite -H;  [simplify_memory | simpl; ucongruence | simpl; ucongruence].
    Ltac simplify_memory_init H:=
      simplify_memory; rewrite -H;  [simplify_memory | simpl; ucongruence | simpl; ucongruence].

    Ltac simplify_memory_in_assm :=
      repeat match goal with
             | Hload: Memory.load ?mem
                                  ?PTR = Some ?v,
                 Hstore: Memory.store ?memprev ?PTR' ?v'
                         = Some ?mem
               |- _ =>
                 erewrite Memory.load_after_store_neq in Hload;
                 try (exact Hstore); try congruence
             end.

    Lemma initialization_correct: forall C stk mem k arg prefix e,
        component_buffer C ->
        (forall (ptr : Pointer.t) (C : Component.id) (b : Block.id) (o : Block.offset),
            Memory.load mem ptr = Some (Ptr (Permission.data, C, b, o)) -> b <> Block.local) ->
        postcondition_steady_state e mem C \/ postcondition_uninitialized prefix e mem C ->
        exists mem' i,
          star CS.kstep (prepare_global_env p)
               [CState C, stk, mem, k, init_check C, arg] E0
               [CState C, stk, mem', k, (E_val (Int i)), arg] /\
            postcondition_steady_state e mem' C /\
            (forall offset,
                offset <> INITFLAG_offset ->
                offset <> LOCALBUF_offset ->
                Memory.load mem (Permission.data, C, Block.local, offset) =
                  Memory.load mem' (Permission.data, C, Block.local, offset)) /\
            (forall C' b offset,
                C <> C' ->
                Memory.load mem (Permission.data, C', b, offset) =
                  Memory.load mem' (Permission.data, C', b, offset)) /\
            (forall C',
                C <> C' ->
                Memory.next_block mem C' = Memory.next_block mem' C') /\
            (forall C' b offset,
                C = C' ->
                b <> Block.local ->
                postcondition_steady_state e mem C ->
                Memory.load mem (Permission.data, C', b, offset) =
                  Memory.load mem' (Permission.data, C', b, offset)) /\
            (forall (ptr : Pointer.t) (C : Component.id) (b : Block.id) (o : Block.offset),
                Memory.load mem' ptr = Some (Ptr (Permission.data, C, b, o)) -> b <> Block.local).
    Proof.
      unfold program_of_trace in Hprog_of_trace.
      destruct (procedures_of_trace t) as [procs_map|] eqn:eprocst; [|discriminate].
      inversion Hprog_of_trace as [Hprog_of_trace'].
      rewrite Hprog_of_trace'.

      move=> C stk mem k arg prefix e C_b load_safe.

      case.
      - move=> [] load_initflag [] load_localbuf postcond.
        exists mem, 0%Z.
        split; [| split; [split | split]]; eauto.
        take_steps; eauto.
        take_steps.
        now apply star_refl.
      - move=> [] load_initflag [] load_localbuf postcond_mem.
        (* TODO: one more step, the alloc step *)
        have: (exists mem',
                  Memory.alloc mem C (buffer_size C) =
                    Some (mem', (Permission.data, C, LOCALBUF_blockid, 0%Z))).
        { move: postcond_mem.
          rewrite /postcondition_event_snapshot_uninitialized
                  /well_formed_memory_snapshot_uninitialized
                  /Memory.alloc.
          move=> [] [] _ [] memC [] ->.
          move: (ComponentMemory.alloc_next_block memC (buffer_size C)) => [] memC' -> ->.
          by eexists. }
        move=> [] mem' mem_mem'.
        destruct (Memory.store_after_load mem' (Permission.data, C, Block.local, LOCALBUF_offset)
                                          Undef
                                          (Ptr (Permission.data, C, LOCALBUF_blockid, 0%Z)))
          as [mem'' mem'_mem'']; eauto.
        rewrite (Memory.load_after_alloc _ _ _ _ _ _ mem_mem'); eauto.
        simpl; ucongruence.
        assert (buf_size_gt0: buffer_size C > 0).
        { move: wf_buffers => /(_ C).
          move: C_b; rewrite /component_buffer /buffer_size /unfold_buffer domm_buffers.
          move=> /dommP [] buf -> /(_ _ Logic.eq_refl).
          rewrite /Buffer.well_formed_buffer.
          case: buf => ? //= => [/Nat.ltb_spec0 size_gt |
                                /andP [] /Nat.ltb_spec0 size_gt _];
                              [rewrite size_nseq|];
                              lia. }
        assert (STAR1:
                 star CS.kstep (prepare_global_env p)
                      [CState C, stk, mem, k, init_check C, arg] E0
                      [CState C, stk, mem'', k, init_local_buffer_expr C, arg]).
        { take_steps; eauto.
          take_steps; eauto.
          rewrite -Nat2Z.inj_0; by apply/inj_gt.
          by rewrite Nat2Z.id; eassumption.
          take_steps. eauto. eauto.
          take_steps.
          eapply star_refl. }
        assert (STAR2:
                 exists (mem''' : Memory.t) (i : Z),
                   star CS.kstep (prepare_global_env p)
                        [CState C, stk, mem'', k, init_local_buffer_expr C, arg] E0
                        [CState C, stk, mem''', k, E_val (Int i), arg] /\
                     postcondition_steady_state e mem''' C /\
                     (forall offset : Z,
                         offset <> INITFLAG_offset ->
                         offset <> LOCALBUF_offset ->
                         Memory.load mem (Permission.data, C, Block.local, offset) =
                           Memory.load mem''' (Permission.data, C, Block.local, offset)) /\
                     (forall C' b offset,
                         C <> C' ->
                         Memory.load mem (Permission.data, C', b, offset) =
                           Memory.load mem''' (Permission.data, C', b, offset)) /\
                     (forall C',
                         C <> C' ->
                         Memory.next_block mem C' = Memory.next_block mem''' C') /\
                     (forall (ptr : Pointer.t) (C : Component.id) (b : Block.id) (o : Block.offset),
                         Memory.load mem''' ptr = Some (Ptr (Permission.data, C, b, o)) ->
                         b <> Block.local)).
        { rewrite /init_local_buffer_expr.
          rewrite /copy_local_datum_expr /buffer_nth.
          clear buf_size_gt0.
          have C_b' := C_b.
          move: C_b (* buf_size_gt0 *); rewrite /component_buffer domm_buffers /buffer_size.
          move=> /dommP [] buf Hbuf. rewrite Hbuf.
          have: Memory.load mem'' (Permission.data, C, Block.local, LOCALBUF_offset) =
                  Some (Ptr (Permission.data, C, LOCALBUF_blockid, 0%Z)) by simplify_memory.
          have: Memory.load mem'' (Permission.data, C, Block.local, INITFLAG_offset) =
                  Some (Int 0) by simplify_memory.
          have: forall o,
              (0 <= o)%Z ->
              Z.to_nat o < size (unfold_buffer buf) ->
              Memory.load mem'' (Permission.data, C, S Block.local, o) =
                Some Undef.
          { intros. simplify_memory'.
            clear -H H0 Hbuf wf_buffers mem_mem'.
            unfold buffer_size in mem_mem'. rewrite Hbuf in mem_mem'.
            unfold Memory.alloc in mem_mem'.
            destruct (mem C) as [memC |]; last discriminate.
            destruct (ComponentMemory.alloc memC (size (unfold_buffer buf)))
                     eqn: Halloc.
            inversion mem_mem'; subst; clear mem_mem'.
            rewrite /Memory.load //=.
            apply ComponentMemory.load_after_alloc_eq with (i := o) in Halloc.
            rewrite setmE eqxx. rewrite Halloc.
            destruct ((o <? Z.of_nat (size (unfold_buffer buf)))%Z) eqn:?.
            move: H => /Z.leb_spec0 -> //=.
            exfalso.
            move: H0 => /inj_lt. rewrite Z2Nat.id; last assumption.
            move=> /Z.ltb_spec0. by rewrite Heqb. }

          clear (* mem'_mem'' *) STAR1.
          remember (size (unfold_buffer buf)) as total_size eqn:Htot_size.
          assert (STAR2:
                   (* forall size_already_done, *)
                   (*   size_already_done + size (unfold_buffer buf) = total_size -> *)
                   forall buf_left_to_copy size_already_done,
                     size_already_done <= size (unfold_buffer buf) ->
                     buf_left_to_copy = drop size_already_done (unfold_buffer buf) ->
                     Memory.load mem'' (Permission.data, C, Block.local, LOCALBUF_offset) =
                       Some (Ptr (Permission.data, C, LOCALBUF_blockid, 0%Z)) ->
                     Memory.load mem'' (Permission.data, C, Block.local, INITFLAG_offset) =
                       Some (Int 0) ->
                     (forall o, (0 <= o)%Z ->
                                Z.to_nat o >= size_already_done ->
                                Z.to_nat o < size (unfold_buffer buf) ->
                                Memory.load mem'' (Permission.data, C, S Block.local, o) =
                                  Some Undef) ->
                     (forall (o: Z),
                         (0 <= o)%Z ->
                         Z.to_nat o < size_already_done ->
                         (* total_size - size buf_left_to_copy -> *)
                         Memory.load mem'' (Permission.data, C, S (Block.local), o) =
                           nth_error (unfold_buffer buf) (Z.to_nat o)
                     (* Memory.load initial_memory (Permission.data, C, Block.local, o) *)
                     ) ->
                     (forall (o: Z),
                         (0 <= o)% Z ->
                         size (unfold_buffer buf) <= Z.to_nat o ->
                         Memory.load mem'' (Permission.data, C, S (Block.local), o) =
                           None) ->
                     (forall b o,
                         Memory.load mem'' (Permission.data, C, S (S b), o) = None) ->
                     (forall (ptr : Pointer.t) (C : Component.id) (b : Block.id) (o : Block.offset),
                         Memory.load mem'' ptr = Some (Ptr (Permission.data, C, b, o)) -> b <> Block.local) ->
                     exists (mem''': Memory.t) (i: Z),
                       star CS.kstep (prepare_global_env p)
                            [CState C, stk, mem'', k, foldr (fun e0 : expr => [eta E_seq e0])
                                                            (E_assign INITFLAG (E_val (Int 1)))
                                                            [seq E_assign
                                                                 (E_binop Add
                                                                          (E_deref LOCALBUF)
                                                                          (E_val (Int (Z.of_nat size_already_done + Z.of_nat i0))))
                                                                 match
                                                                   nth_error buf_left_to_copy i0
                                                                 with
                                                                 | Some Undef => error_expr
                                                                 | Some v => E_val v
                                                                 | None => error_expr
                                                                 end
                                                            | i0 <- iota 0
                                                                         (size buf_left_to_copy)], arg]
                            E0
                            [CState C, stk, mem''', k, E_val (Int i), arg] /\
                         (forall C' b o,
                             C' <> C ->
                             Memory.load mem''' (Permission.data, C', b, o) =
                               Memory.load mem''  (Permission.data, C', b, o)) /\
                         (forall b o,
                             b <> Block.local ->
                             b <> S (Block.local) ->
                             Memory.load mem''' (Permission.data, C, b, o) =
                               Memory.load mem''  (Permission.data, C, b, o)) /\
                         (forall C', Memory.next_block mem''' C' = Memory.next_block mem'' C') /\
                         ((* size buf_left_to_copy = 0 -> *)
                           Memory.load mem'''
                                       (Permission.data, C, Block.local, INITFLAG_offset)
                           = Some (Int 1)) /\
                         (forall o,
                             o <> INITFLAG_offset ->
                             Memory.load mem''' (Permission.data, C, Block.local, o) =
                               Memory.load mem''  (Permission.data, C, Block.local, o)) /\
                         (forall (o: Z),
                             (0 <= o)%Z ->
                             (* Z.to_nat o < total_size - size_left_to_do -> *)
                             Z.to_nat o < size (unfold_buffer buf) ->
                             Memory.load mem''' (Permission.data, C, S (Block.local), o) =
                               nth_error (unfold_buffer buf) (Z.to_nat o)
                         (* Memory.load initial_memory (Permission.data, C, Block.local, o) *)
                         ) /\
                         (forall (o: Z),
                             (0 <= o)% Z ->
                             size (unfold_buffer buf) <= Z.to_nat o ->
                             Memory.load mem''' (Permission.data, C, S (Block.local), o) =
                               None) /\
                         (forall b o,
                             Memory.load mem''' (Permission.data, C, S (S b), o) = None) /\
                         (forall (ptr : Pointer.t) (C : Component.id) (b : Block.id) (o : Block.offset),
                             Memory.load mem''' ptr = Some (Ptr (Permission.data, C, b, o)) -> b <> Block.local)
                 ).
          { move=> buf_left_to_copy.
            elim: buf_left_to_copy mem'' {mem'_mem''} => //=.
            - move=> mem'' size_already_done size_lt drop_sz
                           load_localbuf' load_initflag' load_simulated'
                           load_already_done load_oob load_S_S_b load_safe'.
              destruct (Memory.store_after_load mem''
                                                (Permission.data, C, Block.local, INITFLAG_offset)
                                                (Int 0) (Int 1)) as [mem''' mem''_mem''']; simplify_memory; eauto.
              exists mem'''; exists 1%Z.
              split.
              + take_steps; eauto. eapply star_refl.
              + split; [| split; [| split; [| split; [| split; [| split; [| split; [| split]]]]]]].
                * intros.
                  erewrite (Memory.load_after_store_neq) with
                    (ptr := (Permission.data, C, Block.local, INITFLAG_offset))
                    (ptr' := (Permission.data, C', b, o)); eauto.
                  congruence.
                * intros.
                  erewrite (Memory.load_after_store_neq) with
                    (ptr := (Permission.data, C, Block.local, INITFLAG_offset))
                    (ptr' := (Permission.data, C, b, o)); eauto.
                  congruence.
                * intros. by eapply Memory.next_block_store_stable; eauto.
                * by simplify_memory.
                (* * exists 1%Z. *)
                (*   by simplify_memory. *)
                * intros.
                  erewrite (Memory.load_after_store_neq) with
                    (ptr := (Permission.data, C, Block.local, INITFLAG_offset))
                    (ptr' := (Permission.data, C, Block.local, o)); eauto.
                  congruence.
                * intros.
                  assert (size_already_done = size (unfold_buffer buf)).
                  { apply Nat.le_antisymm. eauto.
                    clear -drop_sz.
                    generalize dependent size_already_done.
                    elim: (unfold_buffer buf).
                    - intros. simpl. lia.
                    - intros; simpl.
                      destruct size_already_done. inversion drop_sz.
                      simpl in drop_sz. apply H in drop_sz.
                      lia. }
                  erewrite (Memory.load_after_store_neq) with
                    (ptr := (Permission.data, C, Block.local, INITFLAG_offset))
                    (ptr' := (Permission.data, C, S Block.local, o)); eauto.
                  eapply load_already_done; eauto; congruence.
                  unfold Block.local; congruence.
                * intros.
                  erewrite (Memory.load_after_store_neq) with
                    (ptr := (Permission.data, C, Block.local, INITFLAG_offset))
                    (ptr' := (Permission.data, C, S Block.local, o)); eauto.
                  unfold Block.local; congruence.
                * intros.
                  erewrite (Memory.load_after_store_neq) with
                    (ptr := (Permission.data, C, Block.local, INITFLAG_offset))
                    (ptr' := (Permission.data, C, S (S b), o)); eauto.
                  unfold Block.local; congruence.
                * intros.
                  destruct (Pointer.eq ptr (Permission.data, C, Block.local, INITFLAG_offset)) eqn:eq_ptr;
                    move: eq_ptr => /Pointer.eqP eq_ptr; subst;
                                    [erewrite Memory.load_after_store_eq in H; eauto; by [] |
                                      erewrite (Memory.load_after_store_neq _ _ _ _ _ _ mem''_mem''') in H; eauto].
            - move=> v ls IH mem'' size_already_done size_lt drop_sz
                       load_localbuf' load_initflag' load_simulated
                       load_already_done load_oob load_S_S_b load_safe'.
              assert (drop_S_sz: ls = drop (size_already_done + 1) (unfold_buffer buf)).
              { rewrite Nat.add_1_r //=.
                clear -size_lt drop_sz.
                remember (unfold_buffer buf) as buff eqn:Hbuf; clear Hbuf.
                generalize dependent ls. generalize dependent size_already_done.
                induction buff.
                - simpl. congruence.
                - simpl. intros size_already_done size_le ls eq.
                  destruct size_already_done.
                  + inversion eq. subst. rewrite drop0. reflexivity.
                  + eapply IHbuff. lia.  eauto.
              }
              assert (S_size_lt: size_already_done + 1 <= size (unfold_buffer buf)).
              { rewrite Nat.add_1_r.
                clear -size_lt drop_sz drop_S_sz.
                subst ls.
                remember (unfold_buffer buf) as buff eqn:Hbuf; clear Hbuf.
                generalize dependent size_already_done.
                induction buff.
                - simpl. congruence.
                - simpl. intros sz size_le eq.
                  rewrite Nat.add_1_r in eq.
                  destruct sz.
                  + lia.
                  + rewrite -Nat.add_1_r in eq.
                    assert (H: sz <= size buff) by lia.
                    specialize (IHbuff sz H eq). lia. }
              destruct (Memory.store_after_load
                          mem''
                          (Permission.data, C, LOCALBUF_blockid, Z.of_nat size_already_done)
                          Undef v) as [mem''' mem''_mem'''].
              { eapply load_simulated; lia. }
              assert (load_localbuf'':
                       Memory.load
                         mem''' (Permission.data, C, Block.local, LOCALBUF_offset) =
                         Some (Ptr (Permission.data, C, LOCALBUF_blockid, 0%Z))).
              { simplify_memory. }
              assert (load_initflag'':
                       Memory.load
                         mem''' (Permission.data, C, Block.local, INITFLAG_offset) =
                         Some (Int 0)).
              { simplify_memory. }
              assert (load_alreadydone': forall o : Z,
                         (0 <= o)%Z ->
                         Z.to_nat o < size_already_done + 1 ->
                         Memory.load mem''' (Permission.data, C, S Block.local, o) =
                           nth_error (unfold_buffer buf) (Z.to_nat o)).
              (* Memory.load initial_memory (Permission.data, C, Block.local, o)). *)
              { intros o o_0 o_lt_S_sz.
                assert (Z.to_nat o < size_already_done \/ Z.to_nat o = size_already_done)
                  as [lt | eq] by lia.
                - rewrite (Memory.load_after_store_neq
                             mem'' (Permission.data, C, S Block.local, Z.of_nat size_already_done)
                             v).
                  eauto. injection. lia.
                  eauto.
                - subst. rewrite Z2Nat.id in mem''_mem'''.
                  rewrite (Memory.load_after_store_eq
                             mem'' (Permission.data, C, S Block.local, o) v).
                  symmetry in drop_sz.
                  rewrite (drop_nth Undef) in drop_sz.
                  symmetry. inversion drop_sz.
                  rewrite (nth_error_nth' _ Undef).
                  { remember (unfold_buffer buf) as buff.
                    remember (Z.to_nat o) as n.
                    clear.
                    assert (List.nth n buff Undef = nth Undef buff n); last congruence.
                    revert n; induction buff; intros.
                    - now destruct n.
                    - simpl. destruct n.
                      + reflexivity.
                      + simpl. rewrite <- IHbuff. reflexivity.
                  }
                  { clear -S_size_lt.
                    rewrite (Nat.add_comm) in S_size_lt. eauto. }
                  { rewrite Nat.add_comm in S_size_lt.
                    apply /ssrnat.leP. lia. }
                  { eauto. }
                  { eauto. }
              }
              assert (load_simulated'': forall o,
                         (0 <= o)%Z ->
                         Z.to_nat o >= size_already_done + 1 ->
                         Z.to_nat o < size (unfold_buffer buf) ->
                         Memory.load mem''' (Permission.data, C, S Block.local, o) =
                           Some Undef).
              { intros o o_0 o_lt_sz o_ge_S_sz.
                - rewrite (Memory.load_after_store_neq
                             mem'' (Permission.data, C, S Block.local, Z.of_nat size_already_done)
                             v); eauto.
                  eapply load_simulated; eauto; try lia.
                  injection; lia.
              }
              assert (load_oob': forall o : Z,
                         (0 <= o)%Z ->
                         size (unfold_buffer buf) <= Z.to_nat o ->
                         Memory.load mem''' (Permission.data, C, S Block.local, o) = None).
              { intros off ? ?.
                erewrite (Memory.load_after_store_neq) with
                  (ptr := (Permission.data, C, S Block.local, Z.of_nat size_already_done))
                  (ptr' := (Permission.data, C, S Block.local, off)); eauto.
                injection. lia.
              }
              assert (load_S_S_b': forall b o,
                         Memory.load mem''' (Permission.data, C, S (S b), o) = None).
              { intros b o.
                erewrite (Memory.load_after_store_neq) with
                  (ptr := (Permission.data, C, S Block.local, Z.of_nat size_already_done))
                  (ptr' := (Permission.data, C, S (S b), o)); eauto.
                unfold Block.local; congruence.
              }
              assert (load_safe'':
                       forall (ptr : Pointer.t) (C : Component.id) (b : Block.id) (o : Block.offset),
                         Memory.load mem''' ptr = Some (Ptr (Permission.data, C, b, o)) ->
                         b <> Block.local).
              { intros.
                destruct (Pointer.eq ptr (Permission.data, C, LOCALBUF_blockid, Z.of_nat size_already_done)) eqn:eq_ptr;
                  move: eq_ptr
                         => /Pointer.eqP eq_ptr; subst;
                            [erewrite (Memory.load_after_store_eq _ _ _ _ mem''_mem''') in H; eauto |
                              erewrite (Memory.load_after_store_neq _ _ _ _ _ _ mem''_mem''') in H; eauto].
                specialize (wf_buffers Hbuf).
                clear -wf_buffers drop_sz H intf prog_buffers t T initial_memory.
                inversion H; subst; clear H.
                unfold Buffer.well_formed_buffer in wf_buffers.
                unfold unfold_buffer in *.
                destruct buf.
                - generalize dependent size_already_done. induction n.
                  + auto.
                  + intros. simpl in *.
                    destruct size_already_done; simpl in *; try discriminate.
                    destruct n; first discriminate.
                    eapply IHn; eauto.
                - generalize dependent size_already_done. induction l.
                  + auto.
                  + intros. simpl in *.
                    destruct size_already_done; simpl in *; try discriminate.
                    destruct l; inversion drop_sz; subst.
                    by simpl in wf_buffers.
                    by simpl in wf_buffers.
                    eapply IHl; eauto. destruct l. by []. simpl in *.
                    move: wf_buffers => /andP [] //=.
              }
              destruct (IH mem''' (size_already_done + 1) S_size_lt drop_S_sz
                           load_localbuf'' load_initflag'' load_simulated''
                           load_alreadydone' load_oob' load_S_S_b' load_safe'') as
                [mem'''' [i' [star_mem'''' [H1 [H2 [H3 [H4 [H5 [H6 [H7 [H8 H9]]]]]]]]]]].
              eexists; eexists.
              split.
              + take_steps.
                eapply star_trans.
                { destruct v eqn:Hv.
                  - take_steps. eauto. eapply star_refl.
                  - take_steps. eauto. eapply star_refl.
                  - take_steps. eauto. eapply star_refl.
                }
                take_steps. rewrite Z.add_0_r. eauto.
                take_step.
                replace (iota 1 (size ls)) with (iota (ssrnat.addn 1 0) (size ls)) by reflexivity.
                rewrite iota_addl -map_comp /comp /=.
                unfold map.
                unfold map in star_mem''''.
                assert (Hrewr: (fix map (s : seq nat) : seq expr :=
                                  match s with
                                  | [::] => [::]
                                  | x :: s' =>
                                      E_assign
                                        (E_binop Add
                                                 (E_deref LOCALBUF)
                                                 (E_val
                                                    (Int
                                                       (Z.of_nat size_already_done +
                                                          Z.pos (Pos.of_succ_nat x)))))
                                        match nth_error ls x with
                                        | Some Undef => error_expr
                                        | Some v0 => E_val v0
                                        | None => error_expr
                                        end ::
                                        map s'
                                  end) =
                                 ((fix map (s : seq nat) : seq expr :=
                                     match s with
                                     | [::] => [::]
                                     | x :: s' => E_assign (E_binop Add
                                                                    (E_deref LOCALBUF)
                                                                    (E_val
                                                                       (Int
                                                                          (Z.of_nat
                                                                             (size_already_done + 1) +
                                                                             Z.of_nat x))))
                                                           match nth_error ls x with
                                                           | Some Undef => error_expr
                                                           | Some v => E_val v
                                                           | None => error_expr
                                                           end ::
                                                           map s'
                                     end))).
                { (* functional extensionality + induction on [s] *)
                  clear.
                  Require Import Coq.Logic.FunctionalExtensionality.
                  apply functional_extensionality.
                  intros s. elim: s.
                  - reflexivity.
                  - intros. rewrite H.
                    replace (Z.of_nat size_already_done + Z.pos (Pos.of_succ_nat a))%Z
                      with (Z.of_nat (size_already_done + 1) + Z.of_nat a)%Z;
                      first reflexivity.
                    clear.
                    by rewrite Zpos_P_of_succ_nat -Nat2Z.inj_succ
                       -2!Nat2Z.inj_add -Nat.add_assoc.
                }
                rewrite Hrewr. eauto. eauto.
              + split; [| split; [| split; [| split; [| split; [| split; [| split]]]]]].
                * intros. rewrite H1; eauto.
                  erewrite (Memory.load_after_store_neq) with
                    (ptr := (Permission.data, C, LOCALBUF_blockid, Z.of_nat size_already_done))
                    (ptr' := (Permission.data, C', b, o)); eauto.
                  congruence.
                * intros. rewrite H2; eauto.
                  erewrite (Memory.load_after_store_neq) with
                    (ptr := (Permission.data, C, LOCALBUF_blockid, Z.of_nat size_already_done))
                    (ptr' := (Permission.data, C, b, o)); eauto.
                  unfold LOCALBUF_blockid, Block.local in *; congruence.
                * intros. rewrite H3; eauto.
                  by eapply Memory.next_block_store_stable; eauto.
                * by [].
                * intros.
                  rewrite H5.
                  erewrite (Memory.load_after_store_neq) with
                    (ptr := (Permission.data, C, LOCALBUF_blockid, Z.of_nat size_already_done))
                    (ptr' := (Permission.data, C, Block.local, o)); eauto.
                  unfold LOCALBUF_blockid, Block.local; congruence. eauto.
                * intros.
                  eapply H6. eauto. lia.
                * intros.
                  rewrite H7; eauto.
                * eauto.
          }
          intros H1' H2' H3'.
          assert (size_ge: 0 <= size (unfold_buffer buf)) by lia.
          assert (left_to_copy: unfold_buffer buf = drop 0 (unfold_buffer buf))
            by now rewrite drop0.
          assert (
              already_copied:
              (forall o : Z,
                  (0 <= o)%Z ->
                  Z.to_nat o < 0 ->
                  Memory.load mem'' (Permission.data, C, S Block.local, o) =
                    nth_error (unfold_buffer buf) (Z.to_nat o))).
          { intros. lia. }
          subst total_size.
          assert (current_sim_buff:
                   forall o : Z,
                     (0 <= o)%Z ->
                     Z.to_nat o >= 0 ->
                     Z.to_nat o < size (unfold_buffer buf) ->
                     Memory.load mem'' (Permission.data, C, S Block.local, o) = Some Undef ).
          { intros. eapply H1'; eauto. }
          assert (load_C_ge_2:
                   forall b off,
                     Memory.load mem (Permission.data, C, S (S b), off) = None).
          { destruct (postcond_mem) as [[_ X] _].
            destruct X as [compMem [X1 X2]].
            intros b off.
            rewrite /Memory.load //= X1.
            destruct (ComponentMemory.load compMem (S (S b)) off) eqn:Y;
              last by [].
            apply ComponentMemory.load_next_block in Y.
            rewrite X2 in Y. unfold LOCALBUF_blockid in Y. by [].
          }
          assert (load_oob: forall o : Z,
                     (0 <= o)%Z ->
                     size (unfold_buffer buf) <= Z.to_nat o ->
                     Memory.load mem'' (Permission.data, C, S Block.local, o) =
                       None).
          { intros. eauto.
            erewrite (Memory.load_after_store_neq _ _ _ _ _ _ mem'_mem'').
            rewrite (Memory.load_after_alloc_eq _ _ _ _ _ _ mem_mem').
            simpl. move: H => /Z.leb_spec0 H; rewrite H.
            case: ifP => //= => /Z.ltb_spec0.
            rewrite Z2Nat.inj_lt. rewrite Nat2Z.id. intros H1.
            unfold buffer_size in H1. rewrite Hbuf in H1. lia.
            by move: H => /Z.leb_spec0.
            by apply Nat2Z.is_nonneg.
            simpl. reflexivity. }
          assert (load_S_S_b: forall b o,
                     Memory.load mem'' (Permission.data, C, S (S b), o) = None).
          { intros.
            erewrite (Memory.load_after_store_neq _ _ _ _ _ _ mem'_mem'').
            (* ComponentMemory.load_next_block *)
            clear -mem_mem' postcond_mem.
            rewrite /Memory.alloc in mem_mem'.
            destruct (mem C) eqn:memC; try discriminate.
            destruct (ComponentMemory.alloc s (buffer_size C)) eqn:alloc_buf.
            inversion mem_mem'; subst; clear mem_mem'.
            apply ComponentMemory.next_block_alloc in alloc_buf as
                [H1 H2].
            rewrite /Memory.load //=. rewrite setmE eqxx.
            destruct (ComponentMemory.load s0 (S (S b)) o) eqn:contra; auto.
            apply ComponentMemory.load_next_block in contra.
            rewrite H2 in contra.
            rewrite ssrnat.addn1 in contra.
            rewrite <- H1 in contra; unfold LOCALBUF_blockid in contra.
            exfalso. unfold ssrnat.leq in contra.
            rewrite ssrnat.subn2 in contra. simpl in contra.
            move: contra => /eqP //=.
          }
          specialize (STAR2 (unfold_buffer buf) 0
                            size_ge left_to_copy H3' H2'
                            current_sim_buff already_copied load_oob load_S_S_b)
            as [mem''' [i' [star_mem''' [H1 [H2 [H3 [H4 [H5 [H6 [H7 [H8 H9]]]]]]]]]]].
          { intros.
            destruct (Pointer.eq ptr (Permission.data, C, Block.local, LOCALBUF_offset)) eqn:eq_ptr;
              move: eq_ptr => /Pointer.eqP eq_ptr; subst;
                              [erewrite Memory.load_after_store_eq in H; eauto |
                                erewrite (Memory.load_after_store_neq _ _ _ _ _ _ mem'_mem'') in H; eauto].
            by inversion H.
            destruct ptr as [[[[]]]]; first by [].
            destruct (i == C) eqn:iC; move: iC => /eqP iC; subst;
                                                  destruct (i0 == LOCALBUF_blockid) eqn:iB; move: iB => /eqP iB; subst.
            erewrite Memory.load_after_alloc_eq in H; eauto. simpl in H.
            move: H; case: ifP => ?. by case: ifP. by [].
            erewrite (Memory.load_after_alloc) in H; eauto. simpl in *. by congruence.
            erewrite (Memory.load_after_alloc) in H; eauto. simpl in *. by congruence.
            erewrite (Memory.load_after_alloc) in H; eauto. simpl in *. by congruence.
          }
          exists mem''', i'.
          split; [| split; [| split; [| split; [| split]]]].
          + simpl in star_mem'''. eapply star_mem'''.
          + { split; [| split].
              - eassumption.
              - by rewrite H5; [eassumption | congruence].
              - constructor.
                ++ intros b Hb.
                   rewrite /memory_shifts_memory_at_shared_addr
                           /memory_renames_memory_at_shared_addr.
                   destruct b as [| b'];
                     first (unfold Block.local in Hb; congruence).

                   exists (C, b').
                   split; [| split].
                   ** by rewrite shift_S_Some.
                   ** move=> //= off v Hload.
                      assert (b' = 0).
                      { destruct b'; auto.
                        rewrite H8 in Hload. discriminate. }
                      subst b'.
                      assert (off_0: (0 <=? off)%Z).
                      { clear -Hload.
                        rewrite /Memory.load /= in Hload.
                        destruct (mem''' C); try discriminate.
                        eapply ComponentMemory.load_offset in Hload.
                        by apply /Z.leb_spec0. }
                      assert (off_size: Z.to_nat off < size (unfold_buffer buf)).
                      { assert (Z.to_nat off < size (unfold_buffer buf) \/
                                  size (unfold_buffer buf) <= Z.to_nat off) as [H|H]
                            by lia.
                        - assumption.
                        - rewrite H7 in Hload; eauto. discriminate.
                          by move: off_0 => /Z.leb_spec0. }
                      destruct postcond_mem as [[[compMem [buff X]] Y] _].
                      destruct X as [X1 [X2 [X3 X4]]].
                      rewrite /Memory.load /= X1 X4.
                      assert (buff = buf) by congruence; subst buff.
                      rewrite ComponentMemory.load_prealloc.
                      rewrite /ComponentMemory.prealloc off_0. simpl.
                      assert (Hrewr: match buf with
                                     | inl size => if (off <? Z.of_nat size)%Z then Some Undef else None
                                     | inr chunk => nth_error chunk (Z.to_nat off)
                                     end =
                                       nth_error (unfold_buffer buf) (Z.to_nat off)
                             ).
                      { clear -off_0. generalize dependent off.
                        destruct buf.
                        - intros. simpl.
                          destruct ((off <? Z.of_nat n)%Z) eqn:Hoff.
                          +
                            remember (Z.to_nat off) as n'.
                            assert (n' < n).
                            { subst.
                              move: Hoff => /Z.ltb_spec0.
                              rewrite -(Nat2Z.id n).
                              rewrite Z2Nat.inj_lt.
                              by rewrite Nat2Z.id.
                              by move: off_0 => /Z.leb_spec0.
                              rewrite Nat2Z.id.
                              by apply Nat2Z.is_nonneg.
                            }
                            clear Heqn' Hoff off off_0.
                            generalize dependent n'.
                            induction n.
                            * by lia.
                            * intros [| n'] => //=.
                              intros H; eapply IHn; lia.
                          + move: Hoff => /Z.ltb_spec0 Hoff.
                            remember (Z.to_nat off) as n'.
                            assert (n <= n').
                            { subst.
                              apply Nat2Z.inj_le. lia. }
                            clear Heqn' Hoff off off_0.
                            generalize dependent n'.
                            induction n.
                            * intros. by destruct n'.
                            * intros [| n'] => //=; [lia |].
                              intros H; eapply IHn; lia.
                        - intros. simpl. eauto.
                      }
                      rewrite Hrewr.
                      pose proof (proj2 (nth_error_Some (unfold_buffer buf) (Z.to_nat off)))
                        as X.
                      specialize (X off_size).
                      destruct (nth_error (unfold_buffer buf) (Z.to_nat off)) as [v' |] eqn:Hv';
                        last congruence.
                      assert (v = v').
                      { rewrite H6 in Hload. rewrite Hv' in Hload. now inversion Hload.
                        by apply /Z.leb_spec0.
                        auto. }
                      subst v'.
                      exists v; split; first reflexivity.
                      rewrite /sigma_shifting_wrap_bid_in_addr /sigma_shifting_lefttoright_addr_bid //=.
                      destruct v; auto.
                      specialize (wf_buffers Hbuf).
                      clear -wf_buffers Hv'. exfalso.
                      unfold Buffer.well_formed_buffer in wf_buffers.
                      destruct buf; simpl in *.
                      --- remember (Z.to_nat off) as n'.
                          clear wf_buffers.
                          move: n n' Hv' {off Heqn'}.
                          induction n.
                          +++ by move=> [].
                          +++ case=> [| n'].
                              *** by [].
                              *** simpl in *. eapply IHn; eauto.
                      --- move: wf_buffers => /andP [] _.
                          clear wf_buffers.
                          remember (Z.to_nat off) as n.
                          move: n {off Heqn} Hv'.
                          induction l.
                          +++ by move=> [].
                          +++ move=> n H /= /andP [] ?.
                              case: n H => [| n] H.
                              *** simpl in *. inversion H. subst.
                                  simpl in *. congruence.
                              *** simpl in *.
                                  eapply IHl; eauto.
                   ** move=> //= off v Hload.
                      assert (b' = 0).
                      { destruct b'; auto.
                        destruct postcond_mem
                          as [[[compMem [buff [memC [Hbuff [Hnext Hprea]]]]] _] _].
                        pose proof (Memory.load_next_block_None) as H.
                        unfold Memory.next_block in H.
                        specialize (H (mem_of_event_inform e)
                                      (Permission.data, C, S b', off)). simpl in H.
                        rewrite memC in H.
                        specialize (H _ Logic.eq_refl).
                        rewrite H in Hload. congruence. rewrite Hnext. apply /ssrnat.leP. lia. }
                      subst b'.
                      assert (off_0: (0 <=? off)%Z).
                      { clear -Hload.
                        rewrite /Memory.load /= in Hload.
                        destruct (mem_of_event_inform e C); try discriminate.
                        eapply ComponentMemory.load_offset in Hload.
                        by apply /Z.leb_spec0. }
                      assert (off_size: Z.to_nat off < size (unfold_buffer buf)).
                      { assert (Z.to_nat off < size (unfold_buffer buf) \/
                                  size (unfold_buffer buf) <= Z.to_nat off) as [H|H]
                            by lia.
                        - assumption.
                        - destruct postcond_mem
                            as [[[compMem [buff [memC [Hbuff [Hnext Hprea]]]]] _] _].
                          rewrite /Memory.load memC Hprea /= in Hload.
                          rewrite ComponentMemory.load_prealloc in Hload.
                          rewrite off_0 in Hload. simpl in Hload.
                          assert (buf = buff) by congruence; subst buff.
                          assert (Hrewr: match buf with
                                         | inl size => if (off <? Z.of_nat size)%Z then Some Undef else None
                                         | inr chunk => nth_error chunk (Z.to_nat off)
                                         end =
                                           nth_error (unfold_buffer buf) (Z.to_nat off)
                                 ).
                          { clear -off_0. generalize dependent off.
                            destruct buf.
                            - intros. simpl.
                              destruct ((off <? Z.of_nat n)%Z) eqn:Hoff.
                              +
                                remember (Z.to_nat off) as n'.
                                assert (n' < n).
                                { subst.
                                  move: Hoff => /Z.ltb_spec0.
                                  rewrite -(Nat2Z.id n).
                                  rewrite Z2Nat.inj_lt.
                                  by rewrite Nat2Z.id.
                                  by move: off_0 => /Z.leb_spec0.
                                  rewrite Nat2Z.id.
                                  by apply Nat2Z.is_nonneg.
                                }
                                clear Heqn' Hoff off off_0.
                                generalize dependent n'.
                                induction n.
                                * by lia.
                                * intros [| n'] => //=.
                                  intros H; eapply IHn; lia.
                              + move: Hoff => /Z.ltb_spec0 Hoff.
                                remember (Z.to_nat off) as n'.
                                assert (n <= n').
                                { subst.
                                  apply Nat2Z.inj_le. lia. }
                                clear Heqn' Hoff off off_0.
                                generalize dependent n'.
                                induction n.
                                * intros. by destruct n'.
                                * intros [| n'] => //=; [lia |].
                                  intros H; eapply IHn; lia.
                            - intros. simpl. eauto.
                          }
                          rewrite Hrewr in Hload.
                          pose proof (proj1 (nth_error_Some (unfold_buffer buf) (Z.to_nat off)))
                            as X.
                          assert (Y: nth_error (unfold_buffer buf) (Z.to_nat off) <> None)
                            by now destruct (nth_error (unfold_buffer buf) (Z.to_nat off)); congruence.
                          eauto.
                      }
                      destruct postcond_mem as [[[compMem [buff X]] Y] _].
                      destruct X as [X1 [X2 [X3 X4]]].
                      destruct Y as [src_compMem [Y1 Y2]].
                      rewrite H6; eauto; last by move: off_0 => /Z.leb_spec0.
                      rewrite /Memory.load /= X1 X4 in Hload.
                      assert (buff = buf) by congruence; subst buff.
                      rewrite ComponentMemory.load_prealloc in Hload.
                      rewrite /ComponentMemory.prealloc off_0 /= in Hload.
                      assert (Hrewr: match buf with
                                     | inl size => if (off <? Z.of_nat size)%Z then Some Undef else None
                                     | inr chunk => nth_error chunk (Z.to_nat off)
                                     end =
                                       nth_error (unfold_buffer buf) (Z.to_nat off)
                             ).
                      { clear -off_0. generalize dependent off.
                        destruct buf.
                        - intros. simpl.
                          destruct ((off <? Z.of_nat n)%Z) eqn:Hoff.
                          +
                            remember (Z.to_nat off) as n'.
                            assert (n' < n).
                            { subst.
                              move: Hoff => /Z.ltb_spec0.
                              rewrite -(Nat2Z.id n).
                              rewrite Z2Nat.inj_lt.
                              by rewrite Nat2Z.id.
                              by move: off_0 => /Z.leb_spec0.
                              rewrite Nat2Z.id.
                              by apply Nat2Z.is_nonneg.
                            }
                            clear Heqn' Hoff off off_0.
                            generalize dependent n'.
                            induction n.
                            * by lia.
                            * intros [| n'] => //=.
                              intros H; eapply IHn; lia.
                          + move: Hoff => /Z.ltb_spec0 Hoff.
                            remember (Z.to_nat off) as n'.
                            assert (n <= n').
                            { subst.
                              apply Nat2Z.inj_le. lia. }
                            clear Heqn' Hoff off off_0.
                            generalize dependent n'.
                            induction n.
                            * intros. by destruct n'.
                            * intros [| n'] => //=; [lia |].
                              intros H; eapply IHn; lia.
                        - intros. simpl. eauto.
                      }
                      rewrite Hrewr in Hload.
                      pose proof (proj2 (nth_error_Some (unfold_buffer buf) (Z.to_nat off)))
                        as X.
                      specialize (X off_size).
                      destruct (nth_error (unfold_buffer buf) (Z.to_nat off)) as [v' |] eqn:Hv';
                        last congruence.
                      assert (v = v') by congruence; subst v'.
                      exists v; split; first reflexivity.
                      rewrite /sigma_shifting_wrap_bid_in_addr /sigma_shifting_lefttoright_addr_bid //=.
                      destruct v; auto.
                      specialize (wf_buffers Hbuf).
                      clear -wf_buffers Hv'. exfalso.
                      unfold Buffer.well_formed_buffer in wf_buffers.
                      destruct buf; simpl in *.
                      --- remember (Z.to_nat off) as n'.
                          clear wf_buffers.
                          move: n n' Hv' {off Heqn'}.
                          induction n.
                          +++ by move=> [].
                          +++ case=> [| n'].
                              *** by [].
                              *** simpl in *. eapply IHn; eauto.
                      --- move: wf_buffers => /andP [] _.
                          clear wf_buffers.
                          remember (Z.to_nat off) as n.
                          move: n {off Heqn} Hv'.
                          induction l.
                          +++ by move=> [].
                          +++ move=> n H /= /andP [] ?.
                              case: n H => [| n] H.
                              *** simpl in *. inversion H. subst.
                                  simpl in *. congruence.
                              *** simpl in *.
                                  eapply IHl; eauto.
                ++ intros b Hb.
                   rewrite H3.
                   destruct postcond_mem
                     as [[[compMem' [buff [memC' [Hbuff [nextBlock prea]]]]]
                            [compMem [memC compMem_next_block]]] _].
                   unfold Memory.next_block in Hb.
                   rewrite memC' in Hb. inversion Hb; subst; clear Hb.
                   simpl. rewrite nextBlock.
                   rewrite (Memory.next_block_store_stable _ _ _ _ _ mem'_mem'').
                   pose proof (Memory.next_block_alloc _ _ _ _ _ mem_mem') as [X1 X2].
                   rewrite X2. simpl in *. eauto.
            }
          + intros. rewrite H5.
            rewrite (Memory.load_after_store_neq _ _ _ _ _ _ mem'_mem'').
            rewrite (Memory.load_after_alloc _ _ _ _ _ _ mem_mem').
            reflexivity.
            simpl; unfold Block.local, LOCALBUF_blockid; congruence.
            congruence. congruence.
          + intros. rewrite H1.
            rewrite (Memory.load_after_store_neq _ _ _ _ _ _ mem'_mem'').
            rewrite (Memory.load_after_alloc _ _ _ _ _ _ mem_mem').
            reflexivity.
            simpl; unfold Block.local, LOCALBUF_blockid; congruence.
            congruence. congruence.
          + intros. rewrite H3.
            rewrite (Memory.next_block_store_stable _ _ _ _ _ mem'_mem'').
            rewrite (Memory.next_block_alloc_neq _ _ _ _ _ _ mem_mem').
            reflexivity. congruence.
          + exact H9.
        }
        destruct STAR2 as [mem''' [i [STAR2 [POST [H1 [H2 [H3 H4]]]]]]].
        eexists; eexists.
        split; [| split; [| split; [| split; [| split; [| split]]]]].
        + eapply star_trans; eauto.
        + assumption.
        + assumption.
        + assumption.
        + assumption.
        + move=> C' b off C_C' b_not_llocal [] load_initflag'.
          congruence.
        + assumption.
          Unshelve.
          congruence.
          unfold Block.local; congruence.
          unfold Block.local; congruence.
          unfold Block.local; congruence.
          congruence.
    Qed.

    (* NOTE: This result could live in Common.Memory, although the current
       statement is very specific to its uses here. *)
    Corollary initialization_correct_component_memory C mem mem':
      (forall b offset,
          Memory.load mem (Permission.data, C, b, offset) =
            Memory.load mem' (Permission.data, C, b, offset)) ->
      Memory.next_block mem C = Memory.next_block mem' C ->
      Memory.next_block mem C = Some LOCALBUF_blockid ->
      (exists off v, Memory.load mem (Permission.data, C, Block.local, off) = Some v) ->
      mem C = mem' C.
    Proof.
      intros Hloads Hnexts Hnext [off [v Hload]].
      destruct (mem C) as [memC |] eqn:HmemC;
        destruct (mem' C) as [mem'C |] eqn:Hmem'C.
      - suffices: (memC = mem'C);
          [congruence |].
        apply ComponentMemory.load_next_block_init_eq.
        + intros b i.
          unfold Memory.load in Hloads. simpl in Hloads.
          specialize (Hloads b i). rewrite HmemC Hmem'C in Hloads.
          assumption.
        + unfold Memory.next_block in Hnexts.
          rewrite HmemC Hmem'C in Hnexts.
          now injection Hnexts.
        + rewrite /Memory.next_block HmemC in Hnext.
          injection Hnext as Hnext.
          assumption.
        + exists off, v.
          rewrite /Memory.load HmemC /= in Hload.
          assumption.
      - unfold Memory.next_block in Hnexts.
        rewrite HmemC Hmem'C in Hnexts.
        discriminate.
      - unfold Memory.next_block in Hnexts.
        rewrite HmemC Hmem'C in Hnexts.
        discriminate.
      - reflexivity.
    Qed.

    (* Print Assumptions initialization_correct_component_memory. *)

    Definition mem_of_trace (t: trace event) :=
      match rev t with
      | [] => initial_memory
      | e :: _ => mem_of_event e
      end.

    Lemma addr_shared_so_far_load_addr_shared_so_far' addr t1 offset cid_load bid_load o:
      addr_shared_so_far addr t1 ->
      Memory.load (mem_of_trace t1) (Permission.data, addr.1, addr.2, offset) =
        Some (Ptr (Permission.data, cid_load, bid_load, o)) ->
      addr_shared_so_far (cid_load, bid_load) t1.
    Proof.
      intros Hshrsfr Hload.
      unfold Memory.load in Hload. simpl in Hload.
      destruct ((mem_of_trace t1) addr.1) eqn:Hmem; try discriminate.
      assert (HIn: (cid_load, bid_load) \in (ComponentMemory.load_block s addr.2)).
      by (rewrite In_in ComponentMemory.load_block_load; eexists; eauto).
      inversion Hshrsfr as [x y z Hreach l Heq | x addr' y z Hshrsfr' Hreach l Heq]. subst.
      - eapply reachable_from_args_is_shared; eauto.
        eapply Reachability.Reachable_step; eauto. rewrite <- surjective_pairing. auto.
        unfold mem_of_trace in Hmem.
        rewrite rev_rcons in Hmem. auto.
      - eapply reachable_from_previously_shared; eauto.
        eapply Reachability.Reachable_transitive; eauto.
        eapply Reachability.Reachable_step; eauto. rewrite <- surjective_pairing.
        eapply Reachability.Reachable_refl.
        by rewrite in_fset1.
        subst. unfold mem_of_trace in Hmem.
        rewrite rev_rcons in Hmem. auto.
    Qed.

    Lemma addr_shared_so_far_inv_1'
          (v vcom: value)
          (mem mem': Memory.t)
          (C : Component.id)
          (renames: shift_value_option (uniform_shift 1) all_zeros_shift vcom = Some v)
          (x: forall C,
              component_buffer C ->
              well_formed_memory_snapshot_steadystate_shift mem mem' C
              \/ (forall b, ~ Reachability.Reachable mem (addr_of_value v) (C, b)))
          (y: forall C b o v,
              Memory.load mem (Permission.data, C, b, o) = Some v ->
              component_buffer C):
      forall Cb b,
        Reachability.Reachable mem (addr_of_value v) (Cb, b) ->
        Reachability.Reachable mem' (addr_of_value vcom) (Cb, S b).
    Proof.
      move=> Cb b reachable.
      generalize dependent vcom.
      remember (addr_of_value v) as init_addr. generalize dependent v.
      remember (Cb, b) as addr. generalize dependent b. generalize dependent Cb.
      induction reachable as [addr in_addr | C' b' addr compMem reachable IH load_compMem in_compMem].
      - move=> Cb b Heqaddr v Heqinit vcom renames; subst.
        destruct v as [| [[[[|] cid] bid] o] |]; try by inversion in_addr.
        rewrite //= in_fset1 in in_addr.
        move: in_addr => /eqP in_addr; inversion in_addr; subst; clear in_addr.
        destruct vcom as [| [[[[|] cid'] bid'] o'] |]; try by inversion renames.
        rewrite /all_zeros_shift /uniform_shift //=
                /rename_addr_option /sigma_shifting_wrap_bid_in_addr
                /sigma_shifting_lefttoright_addr_bid
                /sigma_shifting_lefttoright_option //= in renames.
        destruct bid'; rewrite //= in renames.
        inversion renames; subst; clear renames.
        rewrite ssrnat.subn1 ssrnat.addn0 //=.
        constructor. by rewrite in_fset1.
      - move=> Cb b Heqaddr v Heqinit vcom renames; subst.
        assert (exists o o',
                   Memory.load mem (Permission.data, C', b', o') =
                     Some (Ptr (Permission.data, Cb, b, o)))
          as [o [o' load_mem]].
        { rewrite /Memory.load //=
                  load_compMem.
          apply In_in in in_compMem.
          apply ComponentMemory.load_block_load in in_compMem as [ptro [i in_compMem]].
          exists ptro, i. by rewrite in_compMem. }
        specialize (x C') as [wf | wf]; first now eapply y; eauto.
        2: eapply wf in reachable; contradiction.
        rewrite /well_formed_memory_snapshot_steadystate_shift in wf.
        assert (S_b_not_local: S b' <> Block.local) by by [].
        specialize (wf (S b') S_b_not_local) as [addr [Hshift [H1 H2]]].
        rewrite shift_S_Some in Hshift; inversion Hshift; subst; clear Hshift.
        specialize (H2 o'); rewrite /Memory.load //= in H2.
        specialize (H1 o'); rewrite /Memory.load //= in H1.
        rewrite load_compMem in H2.
        rewrite /Memory.load //= load_compMem in load_mem.
        specialize (H2 _ load_mem) as [v' [H2 H3]].
        destruct (mem' C') as [compMem'|] eqn:mem'_C'; try discriminate.
        destruct v' as [| [[[[|] cid'] bid'] off'] |]; try by inversion H3.
        rewrite /all_zeros_shift /uniform_shift //=
                /rename_addr_option /sigma_shifting_wrap_bid_in_addr
                /sigma_shifting_lefttoright_addr_bid
                /sigma_shifting_lefttoright_option //= in H3.
        destruct bid'; rewrite //= in H3.
        inversion H3; subst; clear H3.
        rewrite ssrnat.subn1 ssrnat.addn0 //=.

        (* We can now apply the constructor and use the induction hypothesis *)
        eapply Reachability.Reachable_step.
        + eapply IH; eauto.
        + eauto.
        + apply In_in.
          apply ComponentMemory.load_block_load.
          eexists; eexists; eauto.
    Qed.

    Lemma addr_shared_so_far_inv_1
          (mem: Memory.t)
          (e e': event)
          (t1 t1': trace event)
          (mem_eq: forall C b o, Memory.load (mem_of_event e') (Permission.data, C, S b, o) =
                              Memory.load mem (Permission.data, C, S b, o))
          (values_rename:
            shift_value_option (uniform_shift 1) all_zeros_shift (arg_of_event e') =
              Some (arg_of_event e))
          (wf1: forall C,
              component_buffer C ->
              C = cur_comp_of_event e ->
              well_formed_memory_snapshot_steadystate_shift (mem_of_event e) mem C)
          (wf2: forall C,
              component_buffer C ->
              well_formed_memory_snapshot_steadystate_shift (mem_of_event e) mem C \/
                (forall b, ~ addr_shared_so_far (C, b) t1))
          (wf3: forall C b,
              component_buffer C ->
              C <> cur_comp_of_event e ->
              ~ addr_shared_so_far (C, b) t1 ->
              ~ addr_shared_so_far (C, b) (rcons t1 e))
          (wf4: forall C b o v,
              Memory.load (mem_of_event e) (Permission.data, C, b, o) = Some v ->
              component_buffer C)
          (traces_rename:
            traces_rename_each_other_option (uniform_shift 1) all_zeros_shift t1' t1):
      forall Cb b,
        addr_shared_so_far (Cb, b) (rcons t1 e) ->
        addr_shared_so_far (Cb, S b) (rcons t1' e').
    Proof.
      assert (wf1': forall C,
                 component_buffer C ->
                 C = cur_comp_of_event e ->
                 well_formed_memory_snapshot_steadystate_shift (mem_of_event e) (mem_of_event e') C).
      { intros C C_b C_cur.
        specialize (wf1 C C_b C_cur).
        unfold well_formed_memory_snapshot_steadystate_shift in *.
        intros [| b] not_local; first (unfold Block.local in not_local; congruence).
        specialize (wf1 (S b) not_local) as [addr [H1 [H2 H3]]].
        eexists. split; last split.
        + eauto.
        + intros offset v Hload. rewrite mem_eq in Hload.
          specialize (H2 _ _ Hload). eauto.
        + intros offset v' Hload.
          specialize (H3 _ _ Hload) as [v [Hload' Hren]].
          rewrite -mem_eq in Hload'.
          eauto. }
      clear wf1. rename wf1' into wf1.
      assert (wf2': forall C,
                 component_buffer C ->
                 well_formed_memory_snapshot_steadystate_shift (mem_of_event e) (mem_of_event e') C \/
                   (forall b, ~ addr_shared_so_far (C, b) t1)).
      { intros C C_b.
        specialize (wf2 C C_b) as [wf2 | wf2]; last now right.
        left.
        unfold well_formed_memory_snapshot_steadystate_shift in *.
        intros [| b] not_local; first (unfold Block.local in not_local; congruence).
        specialize (wf2 (S b) not_local) as [addr [H1 [H2 H3]]].
        eexists. split; last split.
        + eauto.
        + intros offset v Hload. rewrite mem_eq in Hload.
          specialize (H2 _ _ Hload). eauto.
        + intros offset v' Hload.
          specialize (H3 _ _ Hload) as [v [Hload' Hren]].
          rewrite -mem_eq in Hload'.
          eauto. }
      clear wf2. rename wf2' into wf2.
      intros Cb b shared.
      remember (Cb, b) as addr.
      generalize dependent b. generalize dependent Cb.
      remember (rcons t1 e) as t1_e.
      generalize dependent e'. generalize dependent t1'.
      generalize dependent e. generalize dependent t1.
      induction shared as [addr t0 e0 reachable | addr addr' t0 e0 shared IH reachable].
      - intros t1 e eq_traces wf3 wf4 t1' traces_rename e' eq_mem values_rename wf1 wf2 Cb b eq_addr; find_rcons_rcons.
        constructor.
        eapply addr_shared_so_far_inv_1'; eauto.
        intros C C_b.
        destruct (C == (cur_comp_of_event e)) eqn:eC.
        + move: eC => /eqP eC; subst.
          left; now eapply wf1.
        + move: eC => /eqP eC.
          specialize (wf2 C C_b) as [wf | wf]; first now left.
          right. intros b0 reach_b0.
          specialize (wf b0). eapply wf3 in wf; eauto.
          eapply wf. constructor. eauto.
      - intros t1 e eq_traces wf3 wf4 t1' traces_rename e' eq_mem values_rename wf1 wf2 Cb b eq_addr; find_rcons_rcons.
        destruct addr' as [cid bid].
        replace (fset1 (cid, bid)) with (addr_of_value (Ptr (Permission.data, cid, bid, 0%Z)))
          in reachable by reflexivity.
        eapply addr_shared_so_far_inv_1' with (vcom := (Ptr (Permission.data, cid, S bid, 0%Z)))
          in reachable; simpl in reachable; eauto;
          [| by rewrite //= /all_zeros_shift /uniform_shift ssrnat.addn0 ssrnat.subn1 |].
        assert (exists t2 e2, t1 = rcons t2 e2) as [t2 [e2 t2_e2]]; subst.
        { inversion shared; eexists; eexists; eauto. }
        inversion traces_rename; [by destruct t2|].
        find_rcons_rcons.
        eapply reachable_from_previously_shared; eauto.
        specialize (H2 _ shared) as [[cid' bid'] [shift [ren shar]]].
        rewrite //= /all_zeros_shift /uniform_shift //= in shift.
        rewrite /sigma_shifting_wrap_bid_in_addr in shift.
        rewrite /sigma_shifting_lefttoright_addr_bid in shift.
        rewrite /sigma_shifting_lefttoright_option in shift.
        destruct bid'; first discriminate. simpl in shift.
        inversion shift; subst.
        by rewrite ssrnat.subn1 ssrnat.addn0.
        intros C C_b.
        destruct (C == (cur_comp_of_event e)) eqn:eC.
        + move: eC => /eqP eC; subst.
          left; now eapply wf1.
        + move: eC => /eqP eC.
          specialize (wf2 C C_b) as [wf | wf]; first now left.
          right. intros b0 reach_b0.
          specialize (wf b0). eapply wf3 in wf; eauto.
          eapply wf. eapply reachable_from_previously_shared. eauto. eauto.
    Qed.

    Lemma addr_shared_so_far_inv_2'
          (v vcom: value)
          (mem mem': Memory.t)
          (C : Component.id)
          (renames: shift_value_option (uniform_shift 1) all_zeros_shift vcom = Some v)
          (x: forall C,
              component_buffer C ->
              well_formed_memory_snapshot_steadystate_shift mem mem' C
              \/ (forall b, ~ Reachability.Reachable mem (addr_of_value v) (C, b)))
          (y: forall C b o v,
              Memory.load mem' (Permission.data, C, b, o) = Some v ->
              component_buffer C)
          (z: forall C, ~ Reachability.Reachable mem' (addr_of_value vcom) (C, 0)):
      forall Cb b,
        Reachability.Reachable mem' (addr_of_value vcom) (Cb, S b) ->
        Reachability.Reachable mem (addr_of_value v) (Cb, b).
    Proof.
      move=> Cb b reachable.
      generalize dependent v.
      remember (addr_of_value vcom) as init_addr. generalize dependent vcom.
      remember (Cb, S b) as addr. generalize dependent b. generalize dependent Cb.
      induction reachable as [addr in_addr | C' b' addr compMem reachable IH load_compMem in_compMem].
      - move=> Cb b Heqaddr vcom Heqinit v renames x; subst.
        destruct vcom as [| [[[[|] cid] bid] o] |]; try by inversion in_addr.
        rewrite //= in_fset1 in in_addr.
        move: in_addr => /eqP in_addr; inversion in_addr; subst; clear in_addr.
        destruct v as [| [[[[|] cid'] bid'] o'] |]; try by inversion renames.
        rewrite /all_zeros_shift /uniform_shift //=
                /rename_addr_option /sigma_shifting_wrap_bid_in_addr
                /sigma_shifting_lefttoright_addr_bid
                /sigma_shifting_lefttoright_option //= in renames.
        inversion renames; subst; clear renames.
        rewrite ssrnat.subn1 ssrnat.addn0 //=.
        constructor. by rewrite in_fset1.
      - move=> Cb b Heqaddr vcom Heqinit v renames x; subst.
        assert (exists o o',
                   Memory.load mem' (Permission.data, C', b', o') =
                     Some (Ptr (Permission.data, Cb, S b, o)))
          as [o [o' load_mem']].
        { rewrite /Memory.load //=
                  load_compMem.
          apply In_in in in_compMem.
          apply ComponentMemory.load_block_load in in_compMem as [ptro [i in_compMem]].
          exists ptro, i. by rewrite in_compMem. }
        specialize (y _ _ _ _ load_mem').
        assert (x' := x).
        specialize (x C') as [wf | wf]; first exact y.
        + rewrite /well_formed_memory_snapshot_steadystate_shift in wf.
          destruct b' as [| b'].
          * (* Find a contradiction *)
            now eapply z in reachable.
          * assert (S_b_not_local: S b' <> Block.local) by by [].
            specialize (wf (S b') S_b_not_local) as [addr [Hshift [H1 H2]]].
            rewrite shift_S_Some in Hshift; inversion Hshift; subst; clear Hshift.
            specialize (H2 o'); rewrite /Memory.load //= in H2.
            specialize (H1 o'); rewrite /Memory.load //= in H1.
            rewrite load_compMem in H2. rewrite load_compMem in H1.
            rewrite /Memory.load //= load_compMem in load_mem'.
            specialize (H1 _ load_mem') as [v' [H3 H4]].
            destruct (mem C') as [compMem'|] eqn:mem_C'; try discriminate.
            destruct v' as [| [[[[|] cid'] bid'] off'] |]; try by inversion H3.
            rewrite /all_zeros_shift /uniform_shift //=
                    /rename_addr_option /sigma_shifting_wrap_bid_in_addr
                    /sigma_shifting_lefttoright_addr_bid
                    /sigma_shifting_lefttoright_option //= in H4.
            inversion H4; subst; clear H4.

            (* We can now apply the constructor and use the induction hypothesis *)
            eapply Reachability.Reachable_step.
            -- eapply IH; eauto.
            -- eauto.
            -- apply In_in.
               apply ComponentMemory.load_block_load.
               eexists; eexists; eauto.
               rewrite ssrnat.subn1 ssrnat.addn0 in H3. eauto.
        + destruct b' as [| b'].
          * (* Find a contradiction *)
            now eapply z in reachable.
          * specialize (IH C' b' Logic.eq_refl _ Logic.eq_refl _ renames x').
            by eapply wf in IH.
    Qed.

    Lemma addr_shared_so_far_inv_2
          (mem: Memory.t)
          (e e': event)
          (t1 t1': trace event)
          (mem_eq: forall C b o, Memory.load (mem_of_event e') (Permission.data, C, S b, o) =
                              Memory.load mem (Permission.data, C, S b, o))
          (values_rename:
            shift_value_option (uniform_shift 1) all_zeros_shift (arg_of_event e') =
              Some (arg_of_event e))
          (wf1: forall C,
              component_buffer C ->
              C = cur_comp_of_event e ->
              well_formed_memory_snapshot_steadystate_shift (mem_of_event e) mem C)
          (wf2: forall C,
              component_buffer C ->
              well_formed_memory_snapshot_steadystate_shift (mem_of_event e) mem C \/
                (forall b, ~ addr_shared_so_far (C, b) t1))
          (wf3: forall C b,
              component_buffer C ->
              C <> cur_comp_of_event e ->
              ~ addr_shared_so_far (C, b) t1 ->
              ~ addr_shared_so_far (C, b) (rcons t1 e))
          (wf4: forall C b o v,
              Memory.load (mem_of_event e') (Permission.data, C, b, o) = Some v ->
              component_buffer C)
          (wf5: forall ptr C b o,
              Memory.load (mem_of_event e') ptr = Some (Ptr (Permission.data, C, b, o)) ->
              b <> Block.local)
          (traces_rename:
            traces_rename_each_other_option (uniform_shift 1) all_zeros_shift t1' t1):
      forall Cb b,
        addr_shared_so_far (Cb, S b) (rcons t1' e') ->
        addr_shared_so_far (Cb, b) (rcons t1 e).
    Proof.
      assert (wf1': forall C,
                 component_buffer C ->
                 C = cur_comp_of_event e ->
                 well_formed_memory_snapshot_steadystate_shift (mem_of_event e) (mem_of_event e') C).
      { intros C C_b C_cur.
        specialize (wf1 C C_b C_cur).
        unfold well_formed_memory_snapshot_steadystate_shift in *.
        intros [| b] not_local; first (unfold Block.local in not_local; congruence).
        specialize (wf1 (S b) not_local) as [addr [H1 [H2 H3]]].
        eexists. split; last split.
        + eauto.
        + intros offset v Hload. rewrite mem_eq in Hload.
          specialize (H2 _ _ Hload). eauto.
        + intros offset v' Hload.
          specialize (H3 _ _ Hload) as [v [Hload' Hren]].
          rewrite -mem_eq in Hload'.
          eauto. }
      clear wf1. rename wf1' into wf1.
      assert (wf2': forall C,
                 component_buffer C ->
                 well_formed_memory_snapshot_steadystate_shift (mem_of_event e) (mem_of_event e') C \/
                   (forall b, ~ addr_shared_so_far (C, b) t1)).
      { intros C C_b.
        specialize (wf2 C C_b) as [wf2 | wf2]; last now right.
        left.
        unfold well_formed_memory_snapshot_steadystate_shift in *.
        intros [| b] not_local; first (unfold Block.local in not_local; congruence).
        specialize (wf2 (S b) not_local) as [addr [H1 [H2 H3]]].
        eexists. split; last split.
        + eauto.
        + intros offset v Hload. rewrite mem_eq in Hload.
          specialize (H2 _ _ Hload). eauto.
        + intros offset v' Hload.
          specialize (H3 _ _ Hload) as [v [Hload' Hren]].
          rewrite -mem_eq in Hload'.
          eauto. }
      clear wf2. rename wf2' into wf2.
      intros Cb b shared.
      remember (Cb, S b) as addr.
      generalize dependent b. generalize dependent Cb.
      remember (rcons t1' e') as t1'_e'.
      generalize dependent e'. generalize dependent t1'.
      generalize dependent e. generalize dependent t1.
      induction shared as [addr t0 e0 reachable | addr addr' t0 e0 shared IH reachable].
      - intros t1 e wf3 t1' traces_rename e' eq_mem values_rename wf4 wf5
               wf1 wf2 eq_traces Cb b eq_addr; find_rcons_rcons.
        constructor.
        eapply addr_shared_so_far_inv_2' with (mem' := mem_of_event e'); eauto.
        + intros C C_b.
          destruct (C == (cur_comp_of_event e)) eqn:eC.
          * move: eC => /eqP eC; subst.
            left; now eapply wf1.
          * move: eC => /eqP eC.
            specialize (wf2 C C_b) as [wf | wf]; first now left.
            right. intros b0 reach_b0.
            specialize (wf b0). eapply wf3 in wf; eauto.
            eapply wf. constructor. eauto.
        + intros C reachable'.
          clear -reachable' wf5 values_rename.
          remember (C, 0) as addr. generalize dependent C.
          induction reachable'.
          * intros C ?; subst.
            destruct (arg_of_event e') as [| [[[[]]]] |]; try now rewrite in_fset0 in H.
            rewrite /all_zeros_shift /uniform_shift /= in values_rename.
            rewrite /rename_addr_option /sigma_shifting_wrap_bid_in_addr
                    /sigma_shifting_lefttoright_addr_bid
                    /sigma_shifting_lefttoright_option //= in values_rename.
            destruct i0; simpl in values_rename; first discriminate.
            rewrite in_fset1 in H. move: H => /eqP //=.
          * intros C ?; subst.
            eapply In_in in H0. apply ComponentMemory.load_block_load in H0 as [o1 [o2 F]].
            assert (Memory.load (mem_of_event e') (Permission.data, cid, bid, o2) =
                      Some (Ptr (Permission.data, C, 0, o1))).
            Local Transparent Memory.load.
            rewrite /Memory.load //= H F //=.
            Local Opaque Memory.load.
            eapply wf5; eauto.
      - intros t1 e wf3 t1' traces_rename e' eq_mem values_rename wf4 wf5
               wf1 wf2 eq_traces Cb b eq_addr; find_rcons_rcons.
        destruct addr' as [cid bid].

        replace (fset1 (cid, bid)) with (addr_of_value (Ptr (Permission.data, cid, bid, 0%Z)))
          in reachable by reflexivity.

        assert (exists t2' e2', t1' = rcons t2' e2') as [t2' [e2' t2'_e2']]; subst.
        { inversion shared; eexists; eexists; eauto. }
        inversion traces_rename; [by destruct t2'|].
        find_rcons_rcons.

        specialize (H1 _ shared) as [ren [[cid' bid'] [shift shar]]].
        rewrite //= /all_zeros_shift /uniform_shift //= in shift.
        rewrite /sigma_shifting_wrap_bid_in_addr in shift.
        rewrite /sigma_shifting_lefttoright_addr_bid in shift.
        rewrite /sigma_shifting_lefttoright_option in shift.
        destruct bid; first discriminate. simpl in shift.
        rewrite ssrnat.subn1 ssrnat.addn0 in shift; inversion shift; subst; clear shift.
        eapply reachable_from_previously_shared; eauto.
        + replace (fset1 (cid', bid')) with (addr_of_value (Ptr (Permission.data, cid', bid', 0%Z))).
          eapply addr_shared_so_far_inv_2' with (mem' := mem_of_event e'); eauto.
          * by rewrite /= ssrnat.addn0 ssrnat.subn1 //=.
          * intros C C_b.
            destruct (C == (cur_comp_of_event e)) eqn:eC.
            -- move: eC => /eqP eC; subst.
               left; now eapply wf1.
            -- move: eC => /eqP eC.
               specialize (wf2 C C_b) as [wf | wf]; first now left.
               right. intros b0 reach_b0.
               specialize (wf b0). eapply wf3 in wf; eauto.
               eapply wf. eapply reachable_from_previously_shared. eauto. eauto.
          * intros C reachable'.
            clear -reachable' wf5 values_rename.
            remember (C, 0) as addr. generalize dependent C.
            induction reachable'.
            -- intros C ?; subst.
               rewrite in_fset1 in H.
               move: H => /eqP H; inversion H; subst; clear H.
            -- intros C ?; subst.
               eapply In_in in H0. apply ComponentMemory.load_block_load in H0 as [o1 [o2 F]].
               assert (Memory.load (mem_of_event e') (Permission.data, cid, bid, o2) =
                         Some (Ptr (Permission.data, C, 0, o1))).
               Local Transparent Memory.load.
               rewrite /Memory.load //= H F //=.
               Local Opaque Memory.load.
               eapply wf5; eauto.
          * eauto.
    Qed.

    Lemma definability_disciplined_program:
      forall (C : Component.id) (P : Procedure.id) (expr : expr),
        Source.find_procedure
          (Source.prog_procedures p) C P = 
        Some expr -> safe_cont_expr Kstop expr.
    Proof.
      unfold program_of_trace in *.
      destruct (procedures_of_trace t) as [procs|] eqn:eprocs; [|discriminate].
      inversion Hprog_of_trace; subst; clear Hprog_of_trace.
      intros C P expr Hprocs.
      eapply find_procedures_of_trace_Some_procedure_of_trace in Hprocs; eauto;
        last first.
      {
        (* C \in domm intf *)
        eapply Source.find_procedure_prog_interface with
            (p :=
               {|
                Source.prog_interface := intf;
                Source.prog_procedures := procs;
                Source.prog_buffers := mapm (fun=> inr meta_buffer) intf |}
            ); eauto.
        eapply well_formed_events_well_formed_program
          in wf_events as [theprog [Hrewr ?]]; eauto.
        + unfold program_of_trace in Hrewr.
          rewrite eprocs in Hrewr. inversion Hrewr.
            by subst theprog.
        + by eapply domm_t_procs_exported_procedures_of_trace.
      }
      subst.
      rewrite /procedure_of_trace.
      assert (H: safe_cont_expr Kstop (expr_of_trace C P (comp_subtrace C t))).
      { unfold expr_of_trace. unfold switch.
        remember (length [seq expr_of_event C P i | i <- comp_subtrace C t]) as n. clear Heqn.
        revert n.
        elim: (comp_subtrace C t); intros e.
        - simpl. unfold switch. simpl. constructor.
        - intros ? H n.
          simpl. unfold switch. simpl.
          repeat constructor; eauto; try now destruct v0 as [| [[[[]]]] |]; eauto.
          destruct e; subst; eauto.
          + repeat constructor; eauto.
          + repeat constructor; eauto.
          + repeat constructor; eauto.
            destruct v1.
            * repeat constructor; eauto.
            * destruct t1 as [[[[]]]]; repeat constructor; eauto. simpl in *.
              destruct v1 as [| [[[[]]]] |]; eauto.
              destruct v1 as [| [[[[]]]] |]; eauto.
              destruct v1 as [| [[[[]]]] |]; eauto.
              destruct v1 as [| [[[[]]]] |]; eauto.
            * repeat constructor; eauto.
          + repeat constructor; eauto.
          + repeat constructor; eauto.
            Local Transparent binop_of_Ebinop.
            destruct v1 as [| [[[[]]]] |]; destruct v2 as [| [[[[]]]] |]; destruct e; eauto; simpl in *; eauto;
              by case: ifP.
            destruct v1 as [| [[[[]]]] |]; destruct v2 as [| [[[[]]]] |]; destruct e; eauto; simpl in *; eauto;
              by case: ifP.
            Local Opaque binop_of_Ebinop.
          + repeat constructor; eauto.
          + repeat constructor; eauto.
          + repeat constructor; eauto.
      }
      repeat (constructor; eauto).
      unfold init_local_buffer_expr. unfold copy_local_datum_expr. unfold buffer_nth.
      assert (H': safe_cont_expr (Kseq (extcall_check;;
                                        expr_of_trace C P (comp_subtrace C t)) Kstop) (E_assign INITFLAG (E_val (Int 1)))).
      { repeat econstructor; eauto. }
      unfold buffer_size.
      destruct (prog_buffers C) eqn:prog_buffersC; last eauto.
      unfold unfold_buffer. destruct s eqn:eqs0; eauto.
      + clear prog_buffersC eqs0. rewrite foldr_map. simpl in *.
        remember (Kseq (extcall_check;; expr_of_trace C P (comp_subtrace C t)) Kstop) as k; clear Heqk.
        remember 0 as p; clear Heqp. rewrite size_nseq.
        remember (nseq n Undef) as L.
        assert (G: forall i, match nth_error L i with
                             | Some v => v = Undef
                             | None => True
                             end).
        { subst. induction n.
            by destruct i.
            destruct i; simpl; eauto. eapply IHn. }
        clear HeqL.
        revert p.
        induction n.
        * eauto.
        * simpl in *. repeat constructor; eauto.
          specialize (G p). destruct (nth_error L p); subst; repeat constructor; eauto.
      + rewrite foldr_map. simpl in *.
        remember (Kseq (extcall_check;; expr_of_trace C P (comp_subtrace C t)) Kstop) as k; clear Heqk.
        remember 0 as p; clear Heqp.
        remember (size l) as sz; clear Heqsz.
        assert (G: forall i, match nth_error l i with
                             | Some v => forall ptr, v <> Ptr ptr
                             | None => True
                             end).
        { subst. eapply wf_buffers in prog_buffersC.
          simpl in prog_buffersC.
          move: prog_buffersC => /andP [] _ noptr.
          induction l.
          - destruct i; simpl; eauto.
          - move: noptr => /andP [] noptr1 noptr2.
            destruct i; simpl in *; eauto.
            + intros ? ?; subst; by [].
            + eapply IHl. eauto. }
        clear eqs0 prog_buffersC.
        revert p.
        induction sz.
        * eauto.
        * simpl in *. repeat constructor; eauto.
          specialize (G p). destruct (nth_error l p); subst; repeat constructor; eauto.
          destruct v1 as [| |]; subst; repeat constructor; eauto; now specialize (G t0).
    Qed.
    
    Theorem definability_does_not_leak:
      CS.CS.private_pointers_never_leak_S p (uniform_shift 1).
    Proof.
      pose proof (definability_disciplined_program) as G_.
      unfold program_of_trace in *.
      destruct (procedures_of_trace t) as [procs|] eqn:eprocs; [|discriminate].
      inversion Hprog_of_trace; subst; clear Hprog_of_trace.
      eapply star_never_leaks.
      - exact G_.
      - intros ptr v.
        Local Transparent Memory.load.
        rewrite /Memory.load.
        Local Opaque Memory.load.
        destruct ptr as [[[[]]]]; first by [].
        simpl.
        unfold Source.prepare_buffers; rewrite mapmE.
        simpl.
        destruct (mapm (fun=> inr meta_buffer) intf i) eqn:prog_i; last by [].
        simpl. rewrite ComponentMemory.load_prealloc.
        destruct (0 <=? o)%Z eqn:o_lt; last discriminate.
        rewrite setmE.
        case: ifP => ?; last by [].
        destruct s eqn:eqs0.
        + case: ifP => _ []; last by [].
          move=> <- //=.
        + subst. (* unfold p in *. simpl in *. *)
          unfold meta_buffer in prog_i.
          rewrite mapmE in prog_i. destruct (intf i) eqn:intf_i; last discriminate.
          simpl in prog_i. inversion prog_i; subst.
          clear.
          remember (Z.to_nat o) as n; clear Heqn.
          do 11 (destruct n; first by move=> [] <- //=).
          simpl. by induction n.
    Qed.

    Theorem definability_good_Elocal_usage: good_Elocal_usage_program p.
    Proof.
      unfold good_Elocal_usage_program.
      unfold program_of_trace in *.
      destruct (procedures_of_trace t) as [procs|] eqn:eprocs; [|discriminate].
      inversion Hprog_of_trace; subst; clear Hprog_of_trace. simpl.
      unfold NoLeak.buffer_size. simpl.
      intros C P expr Hprocs.
      assert (intf_C: C \in domm intf).
      {(* C \in domm intf *)
        eapply Source.find_procedure_prog_interface with
            (p :=
               {|
                Source.prog_interface := intf;
                Source.prog_procedures := procs;
                Source.prog_buffers := mapm (fun=> inr meta_buffer) intf |}
            ); eauto.
        eapply well_formed_events_well_formed_program
          in wf_events as [theprog [Hrewr ?]]; eauto.
        + unfold program_of_trace in Hrewr.
          rewrite eprocs in Hrewr. inversion Hrewr.
            by subst theprog.
        + by eapply domm_t_procs_exported_procedures_of_trace. }
      eapply find_procedures_of_trace_Some_procedure_of_trace in Hprocs; eauto.
      assert (exists Cintf, intf C = Some Cintf) as [Cintf eq_Cintf] by now apply /dommP.
      subst.
      rewrite /procedure_of_trace.
      simpl; repeat split; auto;
        try by rewrite mapmE eq_Cintf //=.
      - unfold init_local_buffer_expr.
        unfold copy_local_datum_expr.
        unfold buffer_size.
        assert (exists buf, prog_buffers C = Some buf) as [buf eq_buf].
        { apply /dommP. by rewrite -domm_buffers intf_C. }
        rewrite eq_buf.
        unfold buffer_nth. rewrite eq_buf.
        remember (Z.of_nat
                    match mapm (fun=> inr meta_buffer) intf C with
                    | Some buf0 => size (NoLeak.unfold_buffer buf0)
                    | None => 0
                    end) as z.
        assert (G1: (INITFLAG_offset < z)%Z) by now (subst z; rewrite mapmE eq_Cintf //=).
        assert (G2: (LOCALBUF_offset < z)%Z) by now (subst z; rewrite mapmE eq_Cintf //=).
        clear Heqz.
        remember (unfold_buffer buf) as l. clear Heql.
        set (e := fun i => match nth_error l i with
                        | Some (Int _ as v) | Some (Ptr _ as v) => E_val v
                        | _ => error_expr
                        end).
        assert (H: forall i, good_user_of_Elocal_expr z (e i))
          by now rewrite /e => i; destruct (nth_error l i) as [[]| ] => //=.
        replace ([seq E_assign (E_binop Add (E_deref LOCALBUF) (E_val (Int (Z.of_nat i))))
              match nth_error l i with
              | Some (Int _ as v) | Some (Ptr _ as v) => E_val v
              | _ => error_expr
              end
                 | i <- iota 0 (size l)]) with
          [seq E_assign (E_binop Add (E_deref LOCALBUF) (E_val (Int (Z.of_nat i))))
               (e i) | i <- iota 0 (size l)].
        generalize dependent 0.
        elim: l e H.
        + move=> e H n //=.
        + move=> a l IH //= e H [| n];
                repeat split; auto.
        + unfold e. reflexivity.
      - unfold expr_of_trace. unfold switch.
        remember (length [seq expr_of_event C P i | i <- comp_subtrace C t]) as n.
        clear Heqn.
        elim: (comp_subtrace C t) n.
        + by [].
        + move=> e t' IHt' //=.
          repeat split; auto.
          case: e; repeat split; auto;
            try by rewrite mapmE eq_Cintf //=.
          destruct e;
            try by rewrite mapmE eq_Cintf //=.
          destruct v as [| [[[[]]]] |];
            try by rewrite mapmE eq_Cintf //=.
          destruct e0;
            try by rewrite mapmE eq_Cintf //=.
          destruct e;
            try by rewrite mapmE eq_Cintf //=.
          destruct e2;
            try by rewrite mapmE eq_Cintf //=.
          destruct e; destruct e0; destruct e1;
            try by rewrite mapmE eq_Cintf //=.
          destruct e0;
            try by rewrite mapmE eq_Cintf //=.
          destruct e;
            try by rewrite mapmE eq_Cintf //=.
          destruct e;
            try by rewrite mapmE eq_Cintf //=.
          destruct e0;
            try by rewrite mapmE eq_Cintf //=.
          destruct e;
            try by rewrite mapmE eq_Cintf //=.
          destruct e0;
            try by rewrite mapmE eq_Cintf //=.
    Qed.

    (* A proof of relational definability on the right. Existential
      quantification is extended to [cs] and [s], and induction performed on
      the prefix, executing from the initial state. Separately, execution to a
      final state needs to be established. *)
    Lemma definability_gen_rel_right prefix suffix :
      well_bracketed_trace {| cur_comp := Component.main; callers := [::] |} t ->
      well_formed_intermediate_prefix t ->
      t = prefix ++ suffix ->
      exists cs s prefix_inform prefix',
        Star (CS.sem p) (CS.initial_machine_state p) prefix' cs /\
          project_non_inform prefix_inform = prefix' /\
          traces_shift_each_other_option all_zeros_shift (uniform_shift 1) (project_non_inform prefix) prefix' /\
          well_formed_state_r s prefix suffix cs.
    Proof.
      assert (Hprog_of_trace_copy: program_of_trace t = Some p) by auto.
      unfold program_of_trace in Hprog_of_trace_copy.
      destruct (procedures_of_trace t) as [procs_map|] eqn:eprocst; [|discriminate].
      inversion Hprog_of_trace_copy as [Hprog_of_trace'].
      rewrite Hprog_of_trace'.

      assert (Hload_prepare_buffers: forall C o,
                 component_buffer C ->
                 Memory.load (Source.prepare_buffers
                                {|
                                  Source.prog_interface := intf;
                                  Source.prog_procedures := procs_map;
                                  Source.prog_buffers := mapm (fun=> inr meta_buffer) intf |}
                             )
                             (Permission.data, C, Block.local, Z.of_nat o) =
                   nth_error meta_buffer o).
      {
        rewrite Hprog_of_trace'. by eapply load_prepare_buffers.
      }
      
      have Eintf : genv_interface (prepare_global_env p) = intf by subst p.
      have Eprocs : genv_procedures (prepare_global_env p) = Source.prog_procedures p
        by subst p.

      (* Proof by induction on the prefix. Prior to inducting, generalize on
         the suffix. *)
      move=> wb_trace wf_int_pref.
      elim/rev_ind: prefix suffix => [|e prefix IH] /= suffix.
      - (* Base case. *)
        move=> <-.

        assert (Hmain_buffers_p: Component.main \in domm (Source.prog_buffers p)).
        {
          subst p. simpl.
          apply/dommP. rewrite mapmE.
          destruct (intf Component.main); last discriminate. simpl. eauto.
        }
        Local Transparent Memory.load.
        assert (ini_mem_regs: forall reg,
                   reg <> E_R_COM ->
                   Memory.load (Source.prepare_buffers p)
                               (Permission.data, Component.main,
                                 Block.local, reg_offset reg) = Some Undef).
        {
          (** Follows from the definition of meta_buffer. *)
          intros. subst p. unfold Source.prepare_buffers, Memory.load.
          simpl. rewrite !mapmE.
          destruct (intf Component.main); last discriminate; auto.
          simpl. by destruct reg; rewrite ComponentMemory.load_prealloc setmE.
        }

        assert (init_mem_EXTCALL_offet:
                 Memory.load
                   (Source.prepare_buffers p)
                   (Permission.data, Component.main, Block.local, EXTCALL_offset) =
                   Some (Int 1)
               ).
        {
          (** Follows from the definition of meta_buffer. *)
          subst p. unfold Source.prepare_buffers, Memory.load.
          simpl. rewrite !mapmE.
          destruct (intf Component.main); last discriminate; auto.
          simpl. by rewrite ComponentMemory.load_prealloc setmE.
        }

        assert (exists buf_main, prog_buffers Component.main = Some buf_main)
          as [buf_main Hbuf_main].
        by (apply/dommP; rewrite <- domm_buffers; apply/dommP;
            destruct (intf Component.main); last discriminate; eauto).

        assert (C_b : component_buffer Component.main). {
          rewrite /component_buffer. apply /dommP.
          destruct (intf Component.main); last discriminate. now eauto. }
        (* HACK: Invariants take an event argument, but in the empty case no
           events are available. However only the memory is of interest. *)
        set e_dummy := EConst
                         Component.main Undef E_R_ONE
                         initial_memory
                         Machine.Intermediate.Register.init.
        assert (Hpost_ini : postcondition_uninitialized [::] e_dummy (Source.prepare_buffers p) Component.main). {
          split; [| split; [| split; [split |]]].
          - unfold INITFLAG_offset. setoid_rewrite <- Z2Nat.id; try lia.
            rewrite (load_prepare_buffers _ C_b).
            reflexivity.
          - unfold LOCALBUF_offset. setoid_rewrite <- Z2Nat.id; try lia.
            rewrite (load_prepare_buffers _ C_b).
            reflexivity.
          - eexists. exists buf_main.
            split; [| split; [| split]];
              last reflexivity.
            + simpl. rewrite /initial_memory mkfmapfE.
              unfold component_buffer in C_b.
              now rewrite C_b Hbuf_main.
            + assumption.
            + rewrite ComponentMemory.nextblock_prealloc.
              by rewrite domm_set domm0 fsetU0.
          - subst p. rewrite /Source.prepare_buffers
                             mapmE /omap /obind /oapp /=
                             mapmE /omap /obind /oapp /=.
            destruct (intf Component.main); last discriminate.
            eexists. split; first reflexivity.
            rewrite ComponentMemory.nextblock_prealloc.
            now rewrite domm_set domm0 fsetU0.
          - intros b Hshared. simpl in Hshared.
            inversion Hshared; now destruct t0. }

        assert (safe_prep_buffer: forall (ptr : Pointer.t) (C0 : Component.id) (b : Block.id) (o : Block.offset),
                   Memory.load (Source.prepare_buffers p) ptr = Some (Ptr (Permission.data, C0, b, o)) ->
                   b <> Block.local).
        { intros ptr C b o Hload.
          unfold Source.prepare_buffers in Hload.
          simpl in Hload. unfold meta_buffer in Hload. simpl in Hload.
          unfold Memory.load in Hload.
          destruct ptr as [[[[]]]]; first discriminate. simpl in Hload.
          rewrite mapmE in Hload.
          destruct ((Source.prog_buffers p i)) eqn:ebuf; [|discriminate].
          simpl in Hload.
          rewrite ComponentMemory.load_prealloc in Hload.
          move: Hload; case: ifP; last by [].
          move=> _. rewrite setmE. case: ifP => //=.
          move=> _. subst p. simpl in *. unfold meta_buffer in *.
          rewrite mapmE in ebuf. destruct (intf i) eqn:eintf; [|discriminate].
          simpl in *. inversion ebuf. 
          destruct (Z.to_nat o0); first by [].
          do 10 (destruct n; first by []). simpl.
          induction n; by []. }
        destruct (initialization_correct
                    [::]
                    (Kseq (extcall_check;;
                           expr_of_trace Component.main Procedure.main
                                         (comp_subtrace Component.main t)) Kstop)
                    (Int 0) C_b safe_prep_buffer (or_intror Hpost_ini))
          as [mem0 [arg0 [Hstar0 [Hsteady0 [Hsamecomp0 [Hothercomp0 [Hotherblock0 [Hsteady_localbuf Hsafe_ptr]]]]]]]].

        destruct (Memory.store_after_load
                    mem0
                    (Permission.data, Component.main, Block.local, reg_offset E_R_ONE)
                    Undef Undef) as [mem1 Hmem1]; eauto; simplify_memory;
          first (rewrite -Hsamecomp0; try discriminate;
                   by apply ini_mem_regs).

        destruct (Memory.store_after_load
                    mem1
                    (Permission.data, Component.main, Block.local, reg_offset E_R_AUX1)
                    Undef Undef) as [mem2 Hmem2]; eauto; simplify_memory;
          first (rewrite -Hsamecomp0; try discriminate;
                   by apply ini_mem_regs).

        destruct (Memory.store_after_load
                    mem2
                    (Permission.data, Component.main,
                      Block.local, reg_offset E_R_AUX2)
                    Undef Undef) as [mem3 Hmem3]; eauto; simplify_memory;
          first (rewrite -Hsamecomp0; try discriminate;
                   by apply ini_mem_regs).

        destruct (Memory.store_after_load
                    mem3
                    (Permission.data, Component.main,
                      Block.local, reg_offset E_R_RA)
                    Undef Undef) as [mem4 Hmem4]; eauto; simplify_memory;
          first (rewrite -Hsamecomp0; try discriminate;
                   by apply ini_mem_regs).

        destruct (Memory.store_after_load
                    mem4
                    (Permission.data, Component.main,
                      Block.local, reg_offset E_R_SP)
                    Undef Undef) as [mem5 Hmem5]; eauto; simplify_memory;
          first (rewrite -Hsamecomp0; try discriminate;
                   by apply ini_mem_regs).

        destruct (Memory.store_after_load
                    mem5
                    (Permission.data, Component.main,
                      Block.local, reg_offset E_R_ARG)
                    Undef Undef) as [mem6 Hmem6]; eauto; simplify_memory;
          first (rewrite -Hsamecomp0; try discriminate;
                   by apply ini_mem_regs).

        destruct (Memory.store_after_load
                    mem6
                    (Permission.data, Component.main,
                      Block.local, reg_offset E_R_COM)
                    (Int 0%Z) (Int 0%Z)) as [mem7 Hmem7].
        simplify_memory.
        rewrite -Hsamecomp0; try discriminate.
        subst p. unfold Source.prepare_buffers, Memory.load.
        simpl. rewrite !mapmE.
        destruct (intf Component.main); last discriminate; auto.
        simpl. by rewrite ComponentMemory.load_prealloc setmE.

        destruct (Memory.store_after_load
                    mem7
                    (Permission.data, Component.main,
                      Block.local, EXTCALL_offset)
                    (Int 1%Z) (Int 0%Z)) as [mem8 Hmem8].
        simplify_memory.
        rewrite -Hsamecomp0; try discriminate.
        assumption.

        exists (CS.State (Component.main)
                    [:: ]
                    mem8
                    Kstop
                    (expr_of_trace Component.main Procedure.main
                                   (comp_subtrace Component.main t))
                    (Int 0%Z)).

        exists (StackState Component.main []), E0, E0.
        split; [| split; [| split ]].
        + rewrite /CS.initial_machine_state /Source.prog_main.
          erewrite find_procedures_of_trace_main; last (subst p; by eauto).
          take_step.
          eapply star_trans with (t2 := E0);
            first exact Hstar0;
            last reflexivity.

          take_steps; simpl; auto; simplify_memory.

          {
            instantiate (1 := Int 1%Z).
            (** Follows from the definition of meta_buffer. *)
            rewrite -Hsamecomp0; try discriminate.
            subst p. unfold Source.prepare_buffers, Memory.load.
            simpl. rewrite !mapmE.
            destruct (intf Component.main); last discriminate; auto.
            simpl. by rewrite ComponentMemory.load_prealloc setmE.
          }

          Local Transparent loc_of_reg.
          take_steps;
            first exact Hmem1.
          take_steps;
            first exact Hmem2.
          take_steps;
            first exact Hmem3.
          take_steps;
            first exact Hmem4.
          take_steps;
            first exact Hmem5.
          take_steps;
            first exact Hmem6.
          take_steps;
            first exact Hmem7.
          take_steps;
            first exact Hmem8.
          take_steps.
          apply star_refl.
        + reflexivity.
        + now do 2 constructor.
        + econstructor; eauto.
          * now exists [], [].
          * constructor.
            -- move=> C H.
               simplify_memory.
               destruct (Nat.eqb_spec C Component.main) as [| Hneq].
               ++ subst C. rewrite -Hsamecomp0; try discriminate.
                  erewrite <- (Z2Nat.id 0); last lia.
                  rewrite (load_prepare_buffers _ H). reflexivity.
               ++ rewrite -Hothercomp0; try congruence.
                  erewrite <- (Z2Nat.id 0); last lia.
                  rewrite (load_prepare_buffers _ H). reflexivity.
            -- simpl in *.
               move=> _. split.
               ++ move=> ? ? ?; subst.
                  simplify_memory.
               ++ move=> ? ? ?; subst.
                  simplify_memory.
                  rewrite -(Z2Nat.id EXTCALL_offset) /EXTCALL_offset; [| lia].
                  rewrite -Hothercomp0; try congruence.
                  now rewrite Hload_prepare_buffers.
            -- by move=> [].
            -- move=> C r H.
               destruct (Nat.eqb_spec C Component.main) as [| Heq].
               ++ subst C.
                  destruct r; simpl in *; eexists; simplify_memory.
               ++ destruct r; simpl in *;
                    eexists;
                    simplify_memory; rewrite -Hothercomp0; try congruence;
                    match goal with
                    | |- Memory.load _ (_, _, _, ?N) = _ =>
                        rewrite -(Z2Nat.id N); [| lia]
                    end;
                    by rewrite load_prepare_buffers.
            -- move=> C _ C_b'.
               split.
               ++ split.
                  {
                    move=> R n ? ?; subst n.
                    destruct (C == Component.main) eqn:Heq.
                    ** move: Heq => /eqP Heq; subst C.
                       destruct R; simpl in *; simplify_memory.
                    ** move: Heq => /eqP Heq.
                       simplify_memory. erewrite <- Hothercomp0; try congruence.
                       destruct R; simpl in *;
                         (* NOTE: What can we actually say about the initialization
                        of other components? *)
                         match goal with
                         | |- Memory.load _ (_, _, _, ?N) = _ =>
                             rewrite -(Z2Nat.id N); [| lia]
                         end;
                         by rewrite load_prepare_buffers.
                  }
                  {
                    destruct (C == Component.main) eqn:Heq.
                    ** move: Heq => /eqP Heq; subst C.
                       simpl in *; simplify_memory.
                    ** move: Heq => /eqP Heq.
                       simpl in *; simplify_memory.
                       rewrite -Hothercomp0; try congruence.
                       (* NOTE: What can we actually say about the initialization
                        of other components? *)
                       match goal with
                       | |- Memory.load _ (_, _, _, ?N) = _ =>
                           rewrite -(Z2Nat.id N); [| lia]
                       end;
                         by rewrite load_prepare_buffers.
                  }
               ++ destruct (Nat.eqb_spec C Component.main) as [| Heq].
                  ** subst C.
                     split; first congruence.
                     intros _.
                     destruct Hsteady0
                       as [Hinitflag0 [Hlocalbuf0 [Hshift0 Hblock0]]].
                     split; [| split; [| split]].
                     --- by simplify_memory.
                     --- by simplify_memory.
                     --- intros b Hb.
                         rewrite /memory_shifts_memory_at_shared_addr
                                 /memory_renames_memory_at_shared_addr.
                         (* NOTE: Source vs. Intermediate prepare buffers?*)
                         destruct b as [| b']; first contradiction.
                         specialize (Hshift0 _ Hb)
                           as [[cid bid] [Hshift0 [Hrename0 Hrename0']]].
                         eexists. split; first by rewrite shift_S_Some.
                         split.
                         *** intros off v Hload.
                             repeat
                               (erewrite Memory.load_after_store_neq in Hload;
                                last eassumption;
                                last (injection; discriminate)).
                             rewrite shift_S_Some in Hshift0.
                             injection Hshift0 as ? ?; subst cid bid.
                             specialize (Hrename0 _ _ Hload)
                               as [v0 [Hload0 Hrename0]].
                             eexists. split; eassumption.
                         *** simpl. intros off v Hload.
                             rewrite shift_S_Some in Hshift0.
                             injection Hshift0 as ? ?; subst cid bid.
                             specialize (Hrename0' _ _ Hload)
                               as [v0 [Hload0 Hrename0']].
                             eexists. split; last eassumption.
                             by simplify_memory.
                     --- intros b Hnext.
                         repeat
                           (erewrite Memory.next_block_store_stable;
                            last eassumption).
                         rewrite (next_block_initial_memory C_b) in Hnext.
                         injection Hnext as ?; subst b.
                         erewrite Hblock0; first reflexivity.
                         simpl. now rewrite next_block_initial_memory.
                  ** split; last congruence.
                     intros _. split; [| split; [| split]].
                     --- simplify_memory.
                         rewrite /INITFLAG_offset -(Z2Nat.id 2);
                           last lia.
                         rewrite -Hothercomp0; try congruence.
                         by rewrite load_prepare_buffers.
                     --- simplify_memory.
                         rewrite /LOCALBUF_offset -(Z2Nat.id 3);
                           last lia.
                         rewrite -Hothercomp0; try congruence.
                         by rewrite load_prepare_buffers.
                     --- repeat
                         (erewrite Memory.next_block_store_stable;
                          last eassumption).
                         rewrite -Hotherblock0; last congruence.
                         now rewrite next_block_prepare_buffers.
                     --- split.
                         +++ destruct (prog_buffers C) as [buf |] eqn:Hbuf.
                             *** eexists. exists buf.
                                 split; [| split; [| split]];
                                   try reflexivity.
                                 ---- rewrite /initial_memory mkfmapfE.
                                      unfold component_buffer in C_b'.
                                      now rewrite C_b' Hbuf.
                                 ---- rewrite ComponentMemory.nextblock_prealloc.
                                      now rewrite domm_set domm0 fsetU0.
                             *** unfold component_buffer in C_b'.
                                 move: Hbuf => /dommPn => Hcontra.
                                 now rewrite -domm_buffers C_b' in Hcontra.
                         +++ destruct (mem8 C) as [Cmem |] eqn:HCmem.
                             *** exists Cmem. split; first reflexivity.
                                 repeat
                                   (erewrite <- component_memory_after_store_neq in HCmem;
                                    [| eassumption | simpl; congruence]).
                                 unfold Memory.next_block in Hotherblock0.
                                 specialize (Hotherblock0 _ (nesym Heq)).
                                 rewrite HCmem in Hotherblock0.

                                 rewrite -Hprog_of_trace' /Source.prepare_buffers
                                                          mapmE /omap /obind /oapp /=
                                                          mapmE /omap /obind /oapp /=
                                   in Hotherblock0.
                                 destruct (intf C) as [CI |]; last discriminate.
                                 injection Hotherblock0 as Hotherblock.
                                 rewrite -Hotherblock.
                                 rewrite ComponentMemory.nextblock_prealloc.
                                 now rewrite domm_set domm0 fsetU0.
                             *** exfalso.
                                 assert (Hdomm_bufs : C \in domm (Source.prepare_buffers p)). {
                                 rewrite -Hprog_of_trace' /Source.prepare_buffers /=.
                                 rewrite mem_domm
                                         mapmE /omap /obind /oapp
                                         mapmE /omap /obind /oapp.
                                 destruct (intf C) as [CI |] eqn:H_CI;
                                   first reflexivity.
                                 rewrite /component_buffer in C_b'.
                                 move: H_CI => /dommPn.
                                 now rewrite C_b'.
                               }
                               assert (Hdomm0 : C \in domm mem0). {
                                 assert (Hdomm_p : domm (Source.prepare_buffers p) = domm (Source.prog_interface p))
                                   by (by rewrite -Hprog_of_trace' /Source.prepare_buffers
                                                                   /p /program_of_trace
                                                                   !domm_map).
                                 rewrite Hdomm_p in Hdomm_bufs.
                                 erewrite <- CS.comes_from_initial_state_mem_domm in Hdomm_bufs;
                                   last first;
                                   try reflexivity.
                                 - simpl.
                                   rewrite /CS.initial_machine_state /Source.prog_main.
                                   erewrite find_procedures_of_trace_main;
                                     last (by subst; eauto).
                                   take_step.
                                   exact Hstar0.
                                 - eapply closed_program_of_trace; eauto.
                                 - eapply well_formed_events_well_formed_program
                                     in wf_events as [? [? ?]]; eauto.
                                   + erewrite Hprog_of_trace in H. inversion H.
                                     by subst x.
                                   + by eapply domm_t_procs_exported_procedures_of_trace.
                                 - exact Hdomm_bufs.
                               }
                               repeat
                                 (erewrite Memory.domm_store in Hdomm0;
                                  last eassumption).
                                 move: HCmem => /dommPn.
                                 now rewrite Hdomm0.
            -- by move=> [].
            -- move=> ptr C b o.
               destruct (Pointer.eq ptr (Permission.data, Component.main, Block.local, EXTCALL_offset)) eqn:eq_ptr;
                 move: eq_ptr =>
                          /Pointer.eqP eq_ptr; subst;
                          [erewrite (Memory.load_after_store_eq _ _ _ _ Hmem8); eauto; by []
                          | erewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem8); eauto; clear eq_ptr].
               destruct (Pointer.eq ptr (Permission.data, Component.main, Block.local, reg_offset E_R_COM)) eqn:eq_ptr;
                 move: eq_ptr =>
                          /Pointer.eqP eq_ptr; subst;
                          [erewrite (Memory.load_after_store_eq _ _ _ _ Hmem7); eauto; by []
                          | erewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem7); eauto; clear eq_ptr].
               destruct (Pointer.eq ptr (Permission.data, Component.main, Block.local, reg_offset E_R_ARG)) eqn:eq_ptr;
                 move: eq_ptr =>
                          /Pointer.eqP eq_ptr; subst;
                          [erewrite (Memory.load_after_store_eq _ _ _ _ Hmem6); eauto; by []
                          | erewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem6); eauto; clear eq_ptr].
               destruct (Pointer.eq ptr (Permission.data, Component.main, Block.local, reg_offset E_R_SP)) eqn:eq_ptr;
                 move: eq_ptr =>
                          /Pointer.eqP eq_ptr; subst;
                          [erewrite (Memory.load_after_store_eq _ _ _ _ Hmem5); eauto; by []
                          | erewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem5); eauto; clear eq_ptr].
               destruct (Pointer.eq ptr (Permission.data, Component.main, Block.local, reg_offset E_R_RA)) eqn:eq_ptr;
                 move: eq_ptr =>
                          /Pointer.eqP eq_ptr; subst;
                          [erewrite (Memory.load_after_store_eq _ _ _ _ Hmem4); eauto; by []
                          | erewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem4); eauto; clear eq_ptr].
               destruct (Pointer.eq ptr (Permission.data, Component.main, Block.local, reg_offset E_R_AUX2)) eqn:eq_ptr;
                 move: eq_ptr =>
                          /Pointer.eqP eq_ptr; subst;
                          [erewrite (Memory.load_after_store_eq _ _ _ _ Hmem3); eauto; by []
                          | erewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem3); eauto; clear eq_ptr].
               destruct (Pointer.eq ptr (Permission.data, Component.main, Block.local, reg_offset E_R_AUX1)) eqn:eq_ptr;
                 move: eq_ptr =>
                          /Pointer.eqP eq_ptr; subst;
                          [erewrite (Memory.load_after_store_eq _ _ _ _ Hmem2); eauto; by []
                          | erewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem2); eauto; clear eq_ptr].
               destruct (Pointer.eq ptr (Permission.data, Component.main, Block.local, reg_offset E_R_ONE)) eqn:eq_ptr;
                 move: eq_ptr =>
                          /Pointer.eqP eq_ptr; subst;
                          [erewrite (Memory.load_after_store_eq _ _ _ _ Hmem1); eauto; by []
                          | erewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem1); eauto; clear eq_ptr].
          * unfold valid_procedure. now auto.
      - (* Inductive step. *)
        rewrite -catA => Et.
        assert (wf_int_pref' : well_formed_intermediate_prefix (prefix ++ [:: e])).
        { rewrite Et in wf_int_pref.
          eapply well_formed_intermediate_prefix_inv.
          rewrite -catA. eauto. }
        assert (wf_int_pref'' : well_formed_intermediate_prefix prefix).
        { eapply well_formed_intermediate_prefix_inv. eauto. }
        specialize (IH (e :: suffix) Et) as
          [cs [s [prefix_inform [prefix' [Star0 [Hproj [Hshift Hwf_cs]]]]]]].
        (* NOTE: const_map is too weak now! *)

        move: Hwf_cs Star0.
        (* case: cs / => /= _ procs stk mem _ _ arg P -> -> -> [] wb /andP [wf_e wf_suffix] wf_stk wf_mem P_exp. *)
        case: cs / => /= _ procs stk mem _ _ arg P -> -> -> [] /andP [[]] /eqP wf_C_orig wb /andP [wf_e wf_suffix] wf_stk wf_mem P_exp.

        move=> Star0.

        have C_b := valid_procedure_has_block P_exp.
        have C_local := wfmem_counter _ C_b.
        specialize (C_local _ _ wf_mem).
        (* have wf_C: cur_comp s = cur_comp_of_event e *)
        (*   by move: wb => /andP => [[]] => /eqP ->. *)

        have wf_C: cur_comp s = cur_comp_of_event e
          by (rewrite wf_C_orig; reflexivity).

        (* Requires reasoning about the memories *)

        set C := cur_comp s.
        assert (exists mem',
                   Memory.store mem (Permission.data, C, Block.local, 0%Z) (Int (counter_value C (prefix ++ [:: e]))) = Some mem')
          as [mem' Hmem'].
        { eapply Memory.store_after_load. eauto. }

        (* We can simulate the event-producing step as the concatenation
         of three successive stars:

          1. By the IH, an initial star that produces the prefix.

          2. A silent star preceding the event.

          3. A star that contains a step that produces the event
             (which at the source level may now be silent).

           The second star, running up to the point where we are ready
           to execute the proper expression associated with the event
           of interest, is fairly simple to establish. *)

        (* NOTE: The base case was simple, but complications arise in the
         recursive case. The first star can be proved as before, but is it
         exactly what we need? *)

        assert (Star1 : Star (CS.sem p)
                             [CState C, stk, mem , Kstop, expr_of_trace C P (comp_subtrace C t), arg] E0
                             [CState C, stk, mem', Kstop, expr_of_event C P e, arg]).
        { unfold expr_of_trace. rewrite Et 2!comp_subtrace_app. (*simpl.*)
          do 2 setoid_rewrite map_app.
          (* rewrite <- wf_C, Nat.eqb_refl, map_app. simpl. *)
          (* Check Nat.eqb_refl. unfold C. Check map_app. *)
          assert (H := @switch_spec p Permission.data C  stk mem
                                    (map (expr_of_event C P) (comp_subtrace C prefix))
                                    (expr_of_event C P e)
                                    (map (expr_of_event C P) (comp_subtrace C suffix))
                                    E_exit arg).
          (* specialize (C_local prefix mem wf_mem). *)
          rewrite map_length in H. specialize (H C_local).
          destruct H as [mem'' [Hmem'' Hstar]].
          assert (Heq : List.map (expr_of_event C P) (comp_subtrace C [:: e]) =
                          [:: expr_of_event C P e]).
          {
            rewrite /C wf_C /=. now setoid_rewrite Nat.eqb_refl.
          }
          rewrite Heq.
          enough (H : mem'' = mem') by (subst mem''; easy).
          rewrite -> counter_value_snoc in Hmem'.
          unfold cur_comp_of_event in Hmem'.
          simpl in Hmem'.
          unfold C in Hmem'.
          rewrite -> wf_C in Hmem'.
          (* rewrite <- wf_C in Hmem'. *)
          rewrite eq_refl in Hmem'.
          rewrite <- Nat.add_1_r, Nat2Z.inj_add in Hmem''. simpl in Hmem''.
          unfold counter_value in *.

          rewrite <- wf_C in Hmem'. unfold C in Hmem''.
          rewrite Hmem' in Hmem''.
          congruence. }

        (* TODO: Probably split into a separate lemma (after it is in better
         shape). *)
        assert (Star2 : exists e' s' cs',
                   Star (CS.sem p) [CState C, stk, mem', Kstop, expr_of_event C P e, arg] (event_non_inform_of [:: e']) cs' /\
                     well_formed_state_r s' (prefix ++ [e]) suffix cs' /\
                     traces_rename_each_other_option
                       all_zeros_shift
                       (uniform_shift 1)
                       (* metadata_size_lhs *)
                       (* const_map *)
                       (project_non_inform (prefix ++ [e]))
                       (prefix' ++ event_non_inform_of [e'])
               (* shared_locations_have_only_shared_values (CS.s_memory cs') (uniform_shift 1) *)
               (* good_trace_extensional (left_addr_good_for_shifting (uniform_shift 1)) (prefix' ++ event_non_inform_of [e']) *)
               (* match_events e e' *) (* <- Lift to noninformative traces relating only zero/singleton traces *)
               (* event_renames_event_at_shared_addr  *)
               (* /\ e ~ e' *)
               (* NOTE: Here, too, we may need additional conjuncts... *)
               ).
        {

          clear (* Star1 *) (*wf_mem*) C_local (*Hmem'*).
          revert mem' Star1 (*wf_mem'*) Hmem'. rename mem into mem0.
          intros mem Star1 (*wf_mem'*) Hmem.
          (* Case analysis on observable events, which in this rich setting
           extend to calls and returns and various memory accesses and related
           manipulations, of which only calls and returns are observable at
           both levels. *)
          destruct e as [C_ P' new_arg mem' regs C'|C_ ret_val mem' regs C' |C_ ptr v |C_ src dst|C_ |C_ |C_ |C_];
            simpl in wf_C, wf_e(*, wb_suffix*); subst C_.

          - (* Event case: call. *)

            assert (prefix = [::] \/ exists prefix' e', prefix = prefix' ++ [:: e'])
              as [Hprefix | [prefix0 [e1 Hprefix01]]].
            {
              destruct prefix; first by auto.
              right. rewrite lastI -cats1. by eauto.
            }
            { (* Treat empty case separately. *)
              subst prefix. simpl in *.
              assert (Hmain : C = Component.main).
              { unfold C. rewrite Et /= in wb_trace.
                by move: wb_trace => /andP => [[]] => /eqP. }
              subst C. (* NOTE: Avoid substituting to stay close to the standard proof? *)
              destruct (wfmem_ini wf_mem Logic.eq_refl C_b)
                as [Hregs0 [_ Hmaincomp]].
              specialize (Hmaincomp Hmain)
                as [Hload0init [Hload0local Hsnapshot0]].
              assert (Hload0extcall := proj1 (wfmem_extcall_ini wf_mem Logic.eq_refl) _ C_b Hmain). rewrite Hmain in Hload0extcall.

              (*!!!*)

              (* NOTE: These sub-cases are fundamentally identical and easily refactored. *)
              case/andP: wf_e => C_ne_C' /imported_procedure_iff Himport.
              (* (* destruct (wfmem_call wf_mem (Logic.eq_refl _) C_b) as [Hmem Harg]. *) *)
              (* simpl. *)
              pose proof wfmem_extcall_ini wf_mem Logic.eq_refl as [Hextcall_C Hextcall_notC].
              (* pose proof (wfmem_extcall wf_mem Hprefix01) as [Hextcall_C Hextcall_notC]. *)
              have C'_b := valid_procedure_has_block (or_intror (or_introl (closed_intf Himport))).
              assert (C'_not_main : C' <> Component.main). {
                rewrite -Hmain.
                move: C_ne_C' => /eqP => Hcontra.
                now apply nesym. }
              have HextcallC' := Hextcall_notC _ C'_b C'_not_main.
              (* have HextcallC' := Hextcall_notC C' C'_b C'_next_e1. *)


              pose proof (wfmem_meta wf_mem E_R_ONE C'_b) as [v1 Hv1].
              pose proof (wfmem_meta wf_mem E_R_AUX1 C'_b) as [v2 Hv2].
              pose proof (wfmem_meta wf_mem E_R_AUX2 C'_b) as [v3 Hv3].
              pose proof (wfmem_meta wf_mem E_R_RA C'_b) as [v4 Hv4].
              pose proof (wfmem_meta wf_mem E_R_SP C'_b) as [v5 Hv5].
              pose proof (wfmem_meta wf_mem E_R_ARG C'_b) as [v6 Hv6].
              pose proof (wfmem_meta wf_mem E_R_COM C'_b) as [v7 Hv7].
              pose proof (wfmem_meta wf_mem E_R_COM C_b) as [vcom Hvcom].

              pose proof wfmem_ini wf_mem Logic.eq_refl C'_b as [steady_C1 [steady_C2 steady_C3]].
              (* pose proof (wfmem wf_mem Hprefix01) as [steady_C1 [steady_C2 steady_C3]]. *)
              specialize (steady_C2 C'_not_main) as [load_initflag [load_localbuf postcond_C]].


              (* (* Memory operations and initialization check *) *)
              destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
              inversion wf_int_pref' as [| eint Hstep Heint | prefint eint1 eint2 Hsteps Hstep Ht];
                last (destruct prefint as [| ? []]; discriminate).
              inversion Hstep as [tmp1 tmp2 tmp3 tmp4 tmp5 tmp6 | | | | | | |];
                subst tmp1 tmp2 tmp3 tmp4 tmp5 tmp6.
              subst C'0 mem' regs eint new_arg.

              destruct (Memory.store_after_load mem (Permission.data, Component.main, Block.local, EXTCALL_offset)
                                                (Int 0) (Int 1)) as [mem1 Hmem1]; simplify_memory.
              set e := (ECallInform (cur_comp s) P' (Machine.Intermediate.Register.get Machine.R_COM
                                                                                       (Machine.Intermediate.Register.set Machine.R_COM (Int 0) Machine.Intermediate.Register.init)) initial_memory
                                    (Machine.Intermediate.Register.invalidate
                                       (Machine.Intermediate.Register.set Machine.R_COM (Int 0) Machine.Intermediate.Register.init)) C').
              assert (steady_C3': postcondition_steady_state e mem1 C' \/
                                    postcondition_uninitialized [::] e mem1 C'). {
                unfold e. right.
                (* destruct Hinitial0 as [Hinitflag0 [Hlocalbuf0 [Hprealloc0 Hnot_shared0]]]. *)
                destruct postcond_C as [Hblock0 Hprealloc0].
                split; [| split; [| split; [split |]]].
                - by simplify_memory.
                - by simplify_memory.
                - destruct Hprealloc0 as [[Cmem0 [buf [HCmmem0 [Hbuf [Hnext0 Hprealloc]]]]] _].
                  subst Cmem0.
                  eexists. eexists.
                  split; [| split; [| split]];
                    last reflexivity;
                    eassumption.
                - destruct Hprealloc0 as [[Cmem0 [buf [HCmmem0 [Hbuf [Hnext0 Hprealloc]]]]] _].
                  destruct (mem1 C') as [mem1C' |] eqn:Hmem1C'.
                  + eexists. split; first reflexivity.
                    assert (Hnext1 : Memory.next_block mem1 C' = Some LOCALBUF_blockid). {
                      erewrite <- Memory.next_block_store_stable in Hblock0;
                        last eassumption.
                      erewrite <- Memory.next_block_store_stable in Hblock0;
                        last eassumption.
                      exact Hblock0.
                    }
                    rewrite /Memory.next_block Hmem1C' in Hnext1.
                    now injection Hnext1.
                  + erewrite <- component_memory_after_store_neq in Hmem1C';
                      [| eassumption | simpl; congruence].
                    erewrite <- component_memory_after_store_neq in Hmem1C';
                      [| eassumption | simpl; congruence].
                    now rewrite /Memory.load Hmem1C' in load_localbuf.
                - simpl. intros b Hshared.
                  inversion Hshared.
                  + destruct t0 as [| ? []]; try discriminate.
                    injection H1 as ?; subst e0.
                    simpl in *.
                    now apply Reachability.Reachable_fset0 in H3.
                  + destruct t0 as [| ? []]; try discriminate.
                    injection H1 as ?; subst e0.
                    simpl in *.
                    inversion H2; destruct t0; discriminate.
              }

              assert (steady_C3'' := steady_C3').

              (* assert (steady_C3': postcondition_steady_state e1 mem1 C' \/ postcondition_uninitialized prefix0 e1 mem1 C'). *)
              (* { ... } *)

              assert (Hsafe: forall (ptr : Pointer.t) (C : Component.id) (b : Block.id) (o : Block.offset),
                         Memory.load mem1 ptr = Some (Ptr (Permission.data, C, b, o)) -> b <> Block.local).
              { intros ptr C b o Hload.
                destruct (Pointer.eq ptr (Permission.data, Component.main, Block.local, EXTCALL_offset)) eqn:eq_ptr;
                  move: eq_ptr =>
                           /Pointer.eqP eq_ptr; subst;
                           [erewrite Memory.load_after_store_eq in Hload; eauto; by []
                           | erewrite Memory.load_after_store_neq in Hload; eauto; clear eq_ptr].
                rewrite Hmain in Hmem.
                destruct (Pointer.eq ptr (Permission.data, Component.main, Block.local, 0%Z)) eqn:eq_ptr;
                  move: eq_ptr =>
                           /Pointer.eqP eq_ptr; subst;
                           [erewrite Memory.load_after_store_eq in Hload; eauto; by []
                           | erewrite Memory.load_after_store_neq in Hload; eauto; clear eq_ptr].
                eapply wfmem_no_private_ptr; eauto.
              }
              eapply initialization_correct in steady_C3' as [mem2 [i' [Star12 [Postcond1 [Hmem2 [Hmem2' [Hblock2 [Hsteady_localbuf2 Hsafe2]]]]]]]];
                try exact C'_b; last exact Hsafe.

              destruct (Memory.store_after_load mem2 (Permission.data, C', Block.local, reg_offset E_R_ONE)
                                                v1 Undef) as [mem3 Hmem3];
                [simplify_memory_init' Hmem2 |].
              destruct (Memory.store_after_load mem3 (Permission.data, C', Block.local, reg_offset E_R_AUX1)
                                                v2 Undef) as [mem4 Hmem4];
                [simplify_memory_init' Hmem2 |].
              destruct (Memory.store_after_load mem4 (Permission.data, C', Block.local, reg_offset E_R_AUX2)
                                                v3 Undef) as [mem5 Hmem5];
                [simplify_memory_init' Hmem2 |].
              destruct (Memory.store_after_load mem5 (Permission.data, C', Block.local, reg_offset E_R_RA)
                                                v4 Undef) as [mem6 Hmem6];
                [simplify_memory_init' Hmem2 |].
              destruct (Memory.store_after_load mem6 (Permission.data, C', Block.local, reg_offset E_R_SP)
                                                v5 Undef) as [mem7 Hmem7];
                [simplify_memory_init' Hmem2 |].
              destruct (Memory.store_after_load mem7 (Permission.data, C', Block.local, reg_offset E_R_ARG)
                                                v6 Undef) as [mem8 Hmem8];
                [simplify_memory_init' Hmem2 |].
              destruct (Memory.store_after_load mem8 (Permission.data, C', Block.local, reg_offset E_R_COM)
                                                v7 vcom) as [mem9 Hmem9];
                [simplify_memory_init' Hmem2 |].
              destruct (Memory.store_after_load mem9 (Permission.data, C', Block.local, 1%Z)
                                                (Int 1) (Int 0)) as [mem10 Hmem10];
                [simplify_memory_init' Hmem2 |].

              (* ECall (cur_comp s) P' vcom mem1 C' *)
              (* exists e. *)
              (* exists (ECallInform Component.main P' vcom mem1 regs C'). *)
              exists (ECallInform Component.main P' vcom mem1 (Machine.Intermediate.Register.invalidate
                                                            (Machine.Intermediate.Register.set Machine.R_COM (Int 0) Machine.Intermediate.Register.init)) C').
              exists (StackState C' (Component.main :: callers s)).
              eexists.

              split; last split.
              + Local Transparent loc_of_reg.
                take_steps;
                  first (rewrite Hmain; exact Hmem1).
                take_steps;
                  first by simplify_memory.
                (* do 17 (take_step; eauto). simplify_memory. *)

                eapply star_step. simpl.
                apply CS.eval_kstep_sound. simpl.
                rewrite (negbTE C_ne_C').
                rewrite -> imported_procedure_iff in Himport.
                rewrite <- Hprog_of_trace' at 1.
                rewrite Himport.
                rewrite <- imported_procedure_iff in Himport.
                rewrite <- Hprog_of_trace' at 1. simpl.
                now rewrite (find_procedures_of_trace_exp eprocst (closed_intf Himport)).
                take_step.
                eapply star_trans.
                eapply Star12.
                (* destruct POSTCOND as [POSTCOND1 [POSTCOND2 POSTCOND3]]. *)
                take_steps; eauto. simplify_memory_init' Hmem2.
                take_steps. eauto. eauto.
                take_steps. eauto. eauto.
                take_steps. eauto. eauto.
                take_steps. eauto. eauto.
                take_steps. eauto. eauto.
                take_steps. eauto. eauto.
                take_steps. eauto. eauto.
                take_steps. eauto. eauto.
                take_steps.
                eapply star_refl.
                reflexivity.
                rewrite Hmain. reflexivity.
                Local Opaque loc_of_reg.
              + { (** well-formed state *)
                  econstructor; try reflexivity; try eassumption.
                  { destruct s. rewrite -Hmain. exact wb. }
                  { destruct wf_stk as (top & bot & ? & Htop & Hbot). subst stk.
                    eexists []; eexists; simpl; split; eauto.
                    split; [| split]; trivial.
                    -- simplify_memory'. rewrite -Hmem2'; last congruence.
                       simplify_memory. rewrite Hmain in Hload0init; eapply Hload0init.
                    -- eexists arg, P, top, bot.
                       split; first rewrite Hmain; trivial.
                       split; first rewrite Hmain in P_exp; trivial.
                       split; first rewrite Hmain in Htop; trivial.
                       clear Star0 Star1 Star12.
                       elim: (callers s) bot Hbot; trivial.
                       move=> a l IH bot [] H1 H2.
                       fold well_formed_callers in *.
                       split.
                       ++ simplify_memory.
                          destruct (a == C') eqn:eq;
                            move: eq => /eqP eq; subst.
                          simplify_memory.
                          ** now destruct Postcond1.
                          ** rewrite -Hmem2'; last congruence.
                             now simplify_memory.
                       ++ destruct H2 as [? [? [? [? [? [? [? H2]]]]]]].
                          eexists; eexists; eexists; eexists.
                          repeat split; eauto. }
                  (* Reestablish memory well-formedness.
               TODO: Refactor, automate. *)
                  { (* destruct wf_mem as [wfmem_counter wfmem_meta wfmem]. *)
                    constructor.
                    -
                      intros C_ Hcomp.
                      pose proof wfmem_counter wf_mem Hcomp as Hcounter.
                      destruct (Nat.eqb_spec (*Component.main*) C' C_) as [Heq | Hneq].
                      + subst C_.
                        rewrite /counter_value /= in Hcounter.
                        rewrite /counter_value /e /=.
                        rewrite /negb eq_sym in C_ne_C'.
                        destruct (C' == cur_comp s); first discriminate.
                        simpl.
                        simplify_memory'.
                        rewrite -Hmem2; try discriminate.
                        now simplify_memory'.
                      + destruct (Nat.eqb_spec Component.main C_) as [Heq' | Hneq'].
                        * subst C_.
                          rewrite /counter_value /e /= Hmain /=.
                          simplify_memory'.
                          rewrite -Hmem2'; last assumption.
                          rewrite /counter_value /= eqxx /= Hmain in Hmem.
                          now simplify_memory'.
                        * (* Refactor first case and this *)
                          apply nesym in Hneq'.
                          move: Hneq' => /eqP => Hneq'.
                          rewrite /negb in Hneq'.
                          rewrite /counter_value /e /= Hmain /=.
                          destruct (C_ == Component.main) eqn:Heq;
                            first (rewrite Heq in Hneq'; discriminate).
                          rewrite Heq /=.
                          simplify_memory'.
                          rewrite -Hmem2'; last assumption.
                          simplify_memory. injection as ?; subst C_.
                          rewrite Hmain in Heq. discriminate.
                    - discriminate.
                    - intros pref ev Hprefix.
                      destruct pref as [| ? [ | ]]; try discriminate.
                      injection Hprefix as ?; subst ev.
                      split.
                      + intros C_ Hcomp Hnext.
                        rewrite /e /= in Hnext. subst C_.
                        destruct (Nat.eqb_spec Component.main C') as [Heq | Hneq].
                        * subst C'.
                          simplify_memory'.
                        (* apply (proj1 (wfmem_extcall_ini wf_mem Logic.eq_refl) _ Hcomp). *)
                        (* congruence. *)
                        * simplify_memory.
                      (* subst C_. unfold e in Hneq. simpl in Hneq. rewrite Hmain in Hneq. contradiction. *)
                      + intros C_ Hcomp Hnext.
                        (* rewrite /e /= in Hnext. *)
                        destruct (Nat.eqb_spec Component.main C_) as [Heq | Hneq].
                        * subst C_.
                          simplify_memory'.
                          rewrite -Hmem2'; last assumption.
                          now simplify_memory'.
                        * specialize (Hextcall_notC _ Hcomp (nesym Hneq)).
                          simplify_memory;
                            last (injection as ?; subst C_; contradiction).
                          rewrite -Hmem2';
                            last (now rewrite /e /= in Hnext; apply nesym).
                          now simplify_memory'.
                    - intros C_ reg Hcomp.
                      (* Check wfmem_meta wf_mem reg Hcomp. *)
                      destruct (postcondition_event_registers_load reg Hregs0)
                        as [v_reg_reg [Hload0reg _]].
                      (* assert (Hload0reg := Hregs0 (Ereg_to_reg reg) _ Logic.eq_refl). *)
                      (* rewrite reg_to_Ereg_to_reg in Hload0reg. *)
                      destruct (Nat.eqb_spec (* Component.main *) C' C_) as [Heq | Hneq].
                      + subst C_.
                        destruct reg;
                          (eexists; now simplify_memory').
                      + destruct (wfmem_ini wf_mem Logic.eq_refl Hcomp) as [Hregs0' _].
                        destruct (postcondition_event_registers_load reg Hregs0')
                          as [v_reg_reg' [Hload0reg' _]].
                        eexists.
                        (* assert (Hload0reg' := Hregs0' (Ereg_to_reg reg) _ Logic.eq_refl). *)
                        (* rewrite reg_to_Ereg_to_reg in Hload0reg'. *)
                        simplify_memory'.
                        rewrite <- Hmem2'; last assumption.
                        simplify_memory'.
                        exact Hload0reg'.
                    - discriminate.
                    - intros pref ev Hprefix.
                      destruct pref as [| ? [ | ]]; try discriminate.
                      injection Hprefix as ?; subst ev.
                      split; [| split].
                      + {
                        intros reg off Hoffset.
                        unfold e. simpl.
                        destruct reg; subst off;
                          try (eexists; eexists;
                               split;
                               first (now simplify_memory);
                               split;
                               first reflexivity;
                               [now rewrite Machine.Intermediate.Register.gi]).
                        eexists. eexists.
                        split; first (now simplify_memory).
                        split;
                          last (rewrite Machine.Intermediate.Register.gi
                                        Machine.Intermediate.Register.gss //=).
                        rewrite (proj2 Hregs0) in Hvcom.
                        injection Hvcom as ?; subst vcom.
                        reflexivity.
                      }
                      + intros C'' _ ?; subst C''. simpl. (* lookup *)
                        (* This is directly needed for the second sub-goal, but also
                     useful for the fourth one. *)
                        destruct (wfmem_ini wf_mem Logic.eq_refl C_b)
                          as [Hregs [_ Hmaincomp]].
                        specialize (Hmaincomp Hmain) as [Hinitflag [Hlocalbuf [Hshift0 Hblock0]]].
                        destruct Postcond1 as [Hinitflag1 [Hlocalbuf1 Hsteady1]].
                        split; [| split; [| split]].
                        * by simplify_memory'.
                        * by simplify_memory'. (* Trivial due to work up front. *)
                        * (* Nothing shared so far *)
                          intros b Hb. simpl.
                          destruct Hsteady1 as [Hshift1 Hblock1].
                          (* destruct wf_int_pref' as [wf_int_pref' wf_ev_comps']. *)
                          (* inversion wf_int_pref' as [| eint Hstep Heint | prefint eint1 eint2 Hsteps Hstep Ht]; *)
                          (*   last (destruct prefint as [| ? []]; discriminate). *)
                          (* subst eint. *)
                          (* rename s0 into eregs. *)
                          (* inversion Hstep as [| | tmp1 tmp2 tmp3 tmp4 tmp5 tmp6 | | | | |]; *)
                          (*   subst tmp1 tmp2 tmp3 tmp4 tmp5 tmp6; *)
                          (*   subst eregs. *)
                          specialize (Hshift1 _ Hb)
                            as [[cid bid] [Hshift' [Hrename Hrename']]].
                          destruct b as [| b']; first discriminate.
                          rewrite shift_S_Some in Hshift'.
                          injection Hshift' as ? ?; subst cid bid.
                          eexists. split; [| split].
                          -- rewrite shift_S_Some. reflexivity.
                          -- simpl. intros off v' Hload.
                             (* pose proof Hblock0 _ (next_block_initial_memory C_b) *)
                             (*   as Hnext0. *)
                             repeat
                               (erewrite Memory.load_after_store_neq in Hload;
                                last eassumption;
                                last (injection; discriminate)).
                             destruct (Hrename _ _ Hload) as [v'' [Hloadv'' Hrenamev'']].
                             eexists. split; eassumption.
                          -- simpl. intros off v' Hload.
                             rewrite /e /= in Hrename'.
                             destruct (Hrename' _ _ Hload) as [v'' [Hloadv'' Hrenamev'']].
                             eexists. split; last eassumption.
                             now simplify_memory'.
                        * intros b Hnext'. simpl in Hnext'.
                          (* destruct wf_int_pref' as [wf_int_pref' wf_ev_comps']. *)
                          (* inversion wf_int_pref' as [| eint Hstep Heint | prefint eint1 eint2 Hsteps Hstep Ht]; *)
                          (*   last (destruct prefint as [| ? []]; discriminate). *)
                          (* subst eint. *)
                          (* rename s0 into eregs. *)
                          (* inversion Hstep as [| | tmp1 tmp2 tmp3 tmp4 tmp5 tmp6 | | | | |]; *)
                          (*   subst tmp1 tmp2 tmp3 tmp4 tmp5 tmp6; *)
                          (*   subst eregs. *)
                          repeat (erewrite Memory.next_block_store_stable;
                                  last eassumption).
                          rewrite /component_buffer in C'_b.
                          rewrite /Memory.next_block mkfmapfE C'_b in Hnext'.
                          injection Hnext' as Hnext'.
                          rewrite ComponentMemory.nextblock_prealloc in Hnext'.
                          destruct (prog_buffers C') as [buf |] eqn:Hbuf;
                            last (move: Hbuf => /dommPn;
                                                rewrite -domm_buffers => Hcontra;
                                                                           by rewrite C'_b in Hcontra).
                          rewrite domm_set domm0 fsetU0 /= in Hnext'; subst b.
                          destruct Hsteady1 as [Hshift1 Hblock1].
                          erewrite Hblock1; first reflexivity.
                          rewrite /e /=
                                  /Memory.next_block /initial_memory mkfmapfE
                                  C'_b
                                  ComponentMemory.nextblock_prealloc
                                  Hbuf.
                          now rewrite domm_set domm0 fsetU0.
                      + intros C'' Hcomp Hneq.
                        simpl in Hneq.
                        (* rewrite Hmain in Hneq. (* Needed for simplify_memory' *) *)
                        (* rewrite <- Hcomp1 in Hnext. *)
                        destruct (Nat.eqb_spec C'' Component.main) as [Heq | Hneq'].
                        { (* New sub-case *)
                          subst C''.
                          destruct (wfmem_ini wf_mem Logic.eq_refl C_b)
                            as [Hregs [_ Hmaincomp]].
                          specialize (Hmaincomp Hmain) as [Hinitflag [Hlocalbuf [Hshift0 Hblock0]]].
                          left.
                          split; [| split; [| split]].
                          - simplify_memory'.
                            rewrite -Hmem2'; last assumption.
                            rewrite -Hmain.
                            now simplify_memory'.
                          - simplify_memory'.
                            rewrite -Hmem2'; last assumption.
                            rewrite -Hmain.
                            now simplify_memory'.
                          - intros b Hb.
                            destruct b as [| b']; first contradiction.
                            specialize (Hshift0 _ Hb) as [[cid bid] [Hshift0 [Hrename0 Hrename0']]].
                            rewrite shift_S_Some in Hshift0. injection Hshift0 as ? ?; subst cid bid.
                            eexists. split; [| split].
                            * reflexivity.
                            * intros off v Hload.
                              repeat
                                (erewrite Memory.load_after_store_neq in Hload;
                                 last eassumption;
                                 last (injection; discriminate)).
                              rewrite -Hmem2' in Hload; last assumption.
                              repeat
                                (erewrite Memory.load_after_store_neq in Hload;
                                 last eassumption;
                                 last (injection; discriminate)).
                              simpl in *.
                              rewrite -Hmain in Hload.
                              specialize (Hrename0 _ _ Hload) as [v'' [v' Hshiftv]].
                              eexists. split.
                              -- rewrite /= /all_zeros_shift /uniform_shift ssrnat.subn1 ssrnat.addn0 /=.
                                 rewrite -Hmain.
                                 eassumption.
                              -- eassumption.
                            * rewrite /= /all_zeros_shift /uniform_shift ssrnat.subn1 ssrnat.addn0 /=.
                              intros off v Hload.
                              rewrite -Hmain in Hload.
                              specialize (Hrename0' _ _ Hload) as [v'' [v' Hshiftv]].
                              eexists. split.
                              -- simplify_memory'.
                                 rewrite -Hmem2'; last assumption.
                                 simplify_memory'.
                                 rewrite -Hmain. eassumption.
                              -- eassumption.
                          - intros b Hnext.
                            repeat
                              (erewrite Memory.next_block_store_stable; last eassumption).
                            rewrite -Hblock2; last assumption.
                            repeat
                              (erewrite Memory.next_block_store_stable; last eassumption).
                            rewrite /e /= -Hmain in Hnext.
                            rewrite -Hmain.
                            exact (Hblock0 _ Hnext).
                        }
                        destruct (wfmem_ini wf_mem Logic.eq_refl Hcomp)
                          as [Hregs [Hothercomp _]].
                        specialize (Hothercomp Hneq')
                          as [Hinitflag [Hlocalbuf [Hnextblock Hsnapshot]]].
                        (* [Hinitflag [Hlocalbuf [Cmem [HCmem Hnextblock]]]]]. *)
                        right.
                        split; [| split].
                        * simplify_memory'.
                          rewrite -Hmem2'; last now apply nesym.
                          simplify_memory'.
                          exact Hinitflag.
                        * simplify_memory'.
                          rewrite -Hmem2'; last now apply nesym.
                          simplify_memory'.
                          exact Hlocalbuf.
                        (* erewrite Memory.load_after_store_neq; (* TODO: Add to tactic *) *)
                        (*   last exact Hstore4; *)
                        (*   last (fold C; injection; congruence). *)
                        (* simplify_memory'. *)
                        (* exact Hlocalbuf. *)
                        * split; [split |].
                          -- destruct (prog_buffers C'') as [buf |] eqn:HCbuf;
                               last by (rewrite /component_buffer domm_buffers in Hcomp;
                                        move: HCbuf => /dommPn => Hcontra;
                                                                  rewrite Hcomp in Hcontra).
                             eexists. exists buf.
                             split; [| split; [| split]];
                               try reflexivity.
                             ++
                               (* destruct wf_int_pref' as [wf_int_pref' wf_ev_comps']. *)
                               (* inversion wf_int_pref' as [| eint Hstep Heint | prefint eint1 eint2 Hsteps Hstep Ht]; *)
                               (*   last (destruct prefint as [| ? []]; discriminate). *)
                               (* subst eint. *)
                               (* rename s0 into eregs. *)
                               (* inversion Hstep as [| | tmp1 tmp2 tmp3 tmp4 tmp5 tmp6 | | | | |]; *)
                               (*   subst tmp1 tmp2 tmp3 tmp4 tmp5 tmp6; *)
                               (*   subst eregs. *)
                               rewrite /initial_memory /= mkfmapfE.
                               unfold component_buffer in Hcomp.
                               by rewrite Hcomp HCbuf //.
                             ++ rewrite ComponentMemory.nextblock_prealloc
                                        domm_set domm0 /=.
                                by rewrite fsetU0.
                          -- destruct (mem0 C'') as [Cmem |] eqn:HCmem.
                             ++ exists Cmem. split.
                                ** repeat
                                    ((erewrite <- component_memory_after_store_neq;
                                      [| eassumption | intro Hcontra; subst C''; contradiction])
                                     ||
                                       (erewrite <- component_memory_after_alloc_neq;
                                        [| eassumption | intro Hcontra; subst C''; contradiction])).
                                   assert (Hmem12C'' : mem1 C'' = mem2 C''). {
                                    eapply initialization_correct_component_memory; eauto.
                                    - erewrite Memory.next_block_store_stable;
                                        last now eauto.
                                      erewrite Memory.next_block_store_stable;
                                        last now eauto.
                                      assumption.
                                    - exists LOCALBUF_offset, Undef.
                                      now simplify_memory'.
                                  }
                                  rewrite <- Hmem12C''.
                                   repeat
                                     ((erewrite <- component_memory_after_store_neq;
                                       [| eassumption | intro Hcontra; subst C''; contradiction])
                                      ||
                                        (erewrite <- component_memory_after_alloc_neq;
                                         [| eassumption | intro Hcontra; subst C''; contradiction])).

                                   exact HCmem.
                                ** rewrite /Memory.next_block HCmem in Hnextblock.
                                   now injection Hnextblock.
                             ++
                               Local Transparent Memory.load. unfold Memory.load in Hinitflag. Local Opaque Memory.load.
                               rewrite /= HCmem in Hinitflag. discriminate.
                          -- intros b Hshared.
                             rewrite -!cats1 in Hshared. simpl in Hshared.
                             inversion Hshared.
                             ++ destruct t0 as [| ? [|]]; try discriminate.
                                injection H1 as ?; subst e0.
                                now apply Reachability.Reachable_fset0 in H3.
                             ++ destruct t0 as [| ? [|]]; try discriminate.
                                injection H1 as ?; subst e0.
                                inversion H2; now destruct t0.
                    - intros ptr C b o.
                      destruct (Pointer.eq ptr (Permission.data, C', Block.local, 1%Z)) eqn:eq_ptr;
                        move: eq_ptr =>
                                 /Pointer.eqP eq_ptr; subst;
                                 [erewrite (Memory.load_after_store_eq _ _ _ _ Hmem10); eauto; by []
                                 | erewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem10); eauto; clear eq_ptr].
                      destruct (Pointer.eq ptr (Permission.data, C', Block.local, reg_offset E_R_COM)) eqn:eq_ptr;
                        move: eq_ptr =>
                                 /Pointer.eqP eq_ptr; subst;
                                 [erewrite (Memory.load_after_store_eq _ _ _ _ Hmem9); eauto; try by []
                                 | erewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem9); eauto; clear eq_ptr].
                      destruct Hregs0 as [? G].
                      rewrite G in Hvcom. now inversion Hvcom.
                      destruct (Pointer.eq ptr (Permission.data, C', Block.local, reg_offset E_R_ARG)) eqn:eq_ptr;
                        move: eq_ptr =>
                                 /Pointer.eqP eq_ptr; subst;
                                 [erewrite (Memory.load_after_store_eq _ _ _ _ Hmem8); eauto; try by []
                                 | erewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem8); eauto; clear eq_ptr].
                      destruct (Pointer.eq ptr (Permission.data, C', Block.local, reg_offset E_R_SP)) eqn:eq_ptr;
                        move: eq_ptr =>
                                 /Pointer.eqP eq_ptr; subst;
                                 [erewrite (Memory.load_after_store_eq _ _ _ _ Hmem7); eauto; try by []
                                 | erewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem7); eauto; clear eq_ptr].
                      destruct (Pointer.eq ptr (Permission.data, C', Block.local, reg_offset E_R_RA)) eqn:eq_ptr;
                        move: eq_ptr =>
                                 /Pointer.eqP eq_ptr; subst;
                                 [erewrite (Memory.load_after_store_eq _ _ _ _ Hmem6); eauto; try by []
                                 | erewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem6); eauto; clear eq_ptr].
                      destruct (Pointer.eq ptr (Permission.data, C', Block.local, reg_offset E_R_AUX2)) eqn:eq_ptr;
                        move: eq_ptr =>
                                 /Pointer.eqP eq_ptr; subst;
                                 [erewrite (Memory.load_after_store_eq _ _ _ _ Hmem5); eauto; try by []
                                 | erewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem5); eauto; clear eq_ptr].
                      destruct (Pointer.eq ptr (Permission.data, C', Block.local, reg_offset E_R_AUX1)) eqn:eq_ptr;
                        move: eq_ptr =>
                                 /Pointer.eqP eq_ptr; subst;
                                 [erewrite (Memory.load_after_store_eq _ _ _ _ Hmem4); eauto; try by []
                                 | erewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem4); eauto; clear eq_ptr].
                      destruct (Pointer.eq ptr (Permission.data, C', Block.local, reg_offset E_R_ONE)) eqn:eq_ptr;
                        move: eq_ptr =>
                                 /Pointer.eqP eq_ptr; subst;
                                 [erewrite (Memory.load_after_store_eq _ _ _ _ Hmem3); eauto; try by []
                                 | erewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem3); eauto; clear eq_ptr].
                  }
                  { right. left. now apply closed_intf in Himport. }
                }
              + inversion Hshift. subst t0 t'.
                inversion H1.
                * subst prefix'.
                  rewrite <- E0_left at 1.
                  rewrite cats1. unfold Eapp. setoid_rewrite cats1.
                  econstructor; try reflexivity.
                  -- now constructor.
                  -- simpl. intros addr Hshared.
                     rewrite Machine.Intermediate.Register.gss in Hshared.
                     inversion Hshared.
                     ++ destruct t0 as [| ? [|]]; try discriminate.
                        injection H2 as ?; subst e0.
                        now apply Reachability.Reachable_fset0 in H5.
                     ++ destruct t0 as [| ? [|]]; try discriminate.
                        injection H2 as ?; subst e0.
                        inversion H4; now destruct t0.
                  -- simpl. intros addr Hshared.
                     inversion Hshared.
                     ++ destruct t0 as [| ? [|]]; try discriminate.
                        injection H2 as ?; subst e0.
                        assert (vcom = Int 0). { (* Prove this at the top *)
                         rewrite (proj2 Hregs0) in Hvcom.
                         injection Hvcom as ?; subst vcom.
                         reflexivity. }
                       subst vcom.
                        now apply Reachability.Reachable_fset0 in H5.
                     ++ destruct t0 as [| ? [|]]; try discriminate.
                        injection H2 as ?; subst e0.
                        inversion H4; now destruct t0.
                  -- simpl. now auto.
                  -- simpl.
                     rewrite Machine.Intermediate.Register.gss.
                     rewrite (proj2 Hregs0) in Hvcom.
                     injection Hvcom as ?; subst vcom.
                     reflexivity.
                  -- simpl.
                     rewrite Machine.Intermediate.Register.gss.
                     constructor.
                     intros addr Hshared. inversion Hshared.
                     ++ destruct t0 as [| ? [|]]; try discriminate.
                        injection H2 as ?; subst e0.
                        now apply Reachability.Reachable_fset0 in H5.
                     ++ destruct t0 as [| ? [|]]; try discriminate.
                        injection H2 as ?; subst e0.
                        inversion H4; now destruct t0.
                  -- simpl. constructor. intros addr Hshared.
                     inversion Hshared.
                     ++ destruct t0 as [| ? [|]]; try discriminate.
                        injection H2 as ?; subst e0.
                        rewrite (proj2 Hregs0) in Hvcom.
                        injection Hvcom as ?; subst vcom.
                        now apply Reachability.Reachable_fset0 in H5.
                     ++ destruct t0 as [| ? [|]]; try discriminate.
                        injection H2 as ?; subst e0.
                        inversion H4; now destruct t0.
                * now destruct tprefix.
            }

            (** Non-empty trace prefix case **)

            case/andP: wf_e => C_ne_C' /imported_procedure_iff Himport.
            (* destruct (wfmem_call wf_mem (Logic.eq_refl _) C_b) as [Hmem Harg]. *)
            simpl.
            pose proof (wfmem_extcall wf_mem Hprefix01) as [Hextcall_C Hextcall_notC].
            have C'_b := valid_procedure_has_block (or_intror (or_introl (closed_intf Himport))).
            assert (C_next_e1: C = next_comp_of_event e1).
            { destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
              rewrite Hprefix01 in wf_ev_comps'.
              setoid_rewrite <- app_assoc in wf_ev_comps'.
              apply trace_event_components_app_r in wf_ev_comps'.
              setoid_rewrite cats1 in wf_ev_comps'.
              inversion wf_ev_comps'. rewrite lastI in H.
              apply rcons_inj in H. inversion H. subst e2. clear H.
              rewrite -cats1 in H3. apply elt_eq_unit in H3 as [? [? _]]. subst e0 t0.
              by rewrite H0.
            }
            specialize (Hextcall_C C C_b C_next_e1).
            assert (C'_next_e1: C' <> next_comp_of_event e1)
              by (rewrite -C_next_e1 /C; move: C_ne_C' => /eqP; congruence).
            have HextcallC' := Hextcall_notC C' C'_b C'_next_e1.


            pose proof (wfmem_meta wf_mem E_R_ONE C'_b) as [v1 Hv1].
            pose proof (wfmem_meta wf_mem E_R_AUX1 C'_b) as [v2 Hv2].
            pose proof (wfmem_meta wf_mem E_R_AUX2 C'_b) as [v3 Hv3].
            pose proof (wfmem_meta wf_mem E_R_RA C'_b) as [v4 Hv4].
            pose proof (wfmem_meta wf_mem E_R_SP C'_b) as [v5 Hv5].
            pose proof (wfmem_meta wf_mem E_R_ARG C'_b) as [v6 Hv6].
            pose proof (wfmem_meta wf_mem E_R_COM C'_b) as [v7 Hv7].
            pose proof (wfmem_meta wf_mem E_R_COM C_b) as [vcom Hvcom].

            pose proof (wfmem wf_mem Hprefix01) as [steady_C1 [steady_C2 steady_C3]].
            specialize (steady_C2 C C_b C_next_e1) as [load_initflag [load_localbuf postcond_C]].
            specialize (steady_C3 C' C'_b C'_next_e1).


            (* Memory operations and initialization check *)
            destruct (Memory.store_after_load mem (Permission.data, C, Block.local, EXTCALL_offset)
                                              (Int 0) (Int 1)) as [mem1 Hmem1]; simplify_memory.
            assert (steady_C3': postcondition_steady_state e1 mem1 C' \/ postcondition_uninitialized prefix0 e1 mem1 C').
            { destruct steady_C3 as [Hsteady0 | Hinitial0].
              - left.
                destruct Hsteady0 as [Hinitflag0 [Hlocalbuf0 [Hshift0 Hblock0]]].
                split; [| split; [| split]].
                + by simplify_memory.
                + by simplify_memory.
                + intros [| b] Hb; first contradiction.
                  specialize (Hshift0 _ Hb) as [[cid bid] [Hshift0 [Hrename0 Hrename0']]].
                  rewrite shift_S_Some in Hshift0. injection Hshift0 as ? ?; subst cid bid.
                  eexists. split; [| split].
                  * reflexivity.
                  * intros off v Hload.
                    erewrite Memory.load_after_store_neq in Hload;
                      last eassumption;
                      last (injection; discriminate).
                    erewrite Memory.load_after_store_neq in Hload;
                      last eassumption;
                      last (injection; discriminate).
                    specialize (Hrename0 _ _ Hload) as [v'' [v' Hshiftv]].
                    eexists. split.
                    -- rewrite /= /all_zeros_shift /uniform_shift ssrnat.subn1 ssrnat.addn0 /=.
                       eassumption.
                    -- eassumption.
                  * rewrite /= /all_zeros_shift /uniform_shift ssrnat.subn1 ssrnat.addn0 /=.
                    intros off v Hload.
                    specialize (Hrename0' _ _ Hload) as [v'' [v' Hshiftv]].
                    eexists. split.
                    -- by simplify_memory.
                    -- eassumption.
                + intros b Hnext.
                  erewrite Memory.next_block_store_stable; last eassumption.
                  erewrite Memory.next_block_store_stable; last eassumption.
                  exact (Hblock0 _ Hnext).
              - right.
                destruct Hinitial0 as [Hinitflag0 [Hlocalbuf0 [Hprealloc0 Hnot_shared0]]].
                split; [| split; [| split; [split |]]].
                + by simplify_memory.
                + by simplify_memory.
                + destruct Hprealloc0 as [[Cmem0 [buf [HCmmem0 [Hbuf [Hnext0 Hprealloc]]]]] _].
                  subst Cmem0.
                  eexists. eexists.
                  split; [| split; [| split]];
                    last reflexivity; eassumption.
                + destruct Hprealloc0 as [_ Hblock0].
                  destruct Hblock0 as [Cmem0 [HCmem0 Hblock0]].
                  exists Cmem0. split.
                  * erewrite <- component_memory_after_store_neq;
                      [| eassumption |];
                      last (simpl; intros ?; subst C'; rewrite /C //= in C_ne_C').
                    erewrite <- component_memory_after_store_neq;
                      [| eassumption |];
                      last (simpl; intros ?; subst C'; rewrite /C //= in C_ne_C').
                    exact HCmem0.
                  * exact Hblock0.
                + exact Hnot_shared0.
            }

            assert (steady_C3'' := steady_C3').

            assert (Hsafe: forall (ptr : Pointer.t) (C : Component.id) (b : Block.id) (o : Block.offset),
                       Memory.load mem1 ptr = Some (Ptr (Permission.data, C, b, o)) -> b <> Block.local).
            { intros ptr C0 b0 o0 Hload.
              destruct (Pointer.eq ptr (Permission.data, C, Block.local, EXTCALL_offset)) eqn:eq_ptr;
                move: eq_ptr =>
                         /Pointer.eqP eq_ptr; subst;
                         [erewrite Memory.load_after_store_eq in Hload; eauto; by []
                         | erewrite Memory.load_after_store_neq in Hload; eauto; clear eq_ptr].
              destruct (Pointer.eq ptr (Permission.data, C, Block.local, 0%Z)) eqn:eq_ptr;
                move: eq_ptr =>
                         /Pointer.eqP eq_ptr; subst;
                         [erewrite Memory.load_after_store_eq in Hload; eauto; by []
                         | erewrite Memory.load_after_store_neq in Hload; eauto; clear eq_ptr].
              eapply wfmem_no_private_ptr; eauto.
            }
            eapply initialization_correct in steady_C3' as [mem2 [i' [Star12 [Postcond1 [Hmem2 [Hmem2' [Hblock2 [Hsteady_localbuf2 Hsafe2]]]]]]]];
              try exact C'_b; last exact Hsafe.

            destruct (Memory.store_after_load mem2 (Permission.data, C', Block.local, reg_offset E_R_ONE)
                                              v1 Undef) as [mem3 Hmem3];
              [simplify_memory_init Hmem2 |].
            destruct (Memory.store_after_load mem3 (Permission.data, C', Block.local, reg_offset E_R_AUX1)
                                              v2 Undef) as [mem4 Hmem4];
              [simplify_memory_init Hmem2 |].
            destruct (Memory.store_after_load mem4 (Permission.data, C', Block.local, reg_offset E_R_AUX2)
                                              v3 Undef) as [mem5 Hmem5];
              [simplify_memory_init Hmem2 |].
            destruct (Memory.store_after_load mem5 (Permission.data, C', Block.local, reg_offset E_R_RA)
                                              v4 Undef) as [mem6 Hmem6];
              [simplify_memory_init Hmem2 |].
            destruct (Memory.store_after_load mem6 (Permission.data, C', Block.local, reg_offset E_R_SP)
                                              v5 Undef) as [mem7 Hmem7];
              [simplify_memory_init Hmem2 |].
            destruct (Memory.store_after_load mem7 (Permission.data, C', Block.local, reg_offset E_R_ARG)
                                              v6 Undef) as [mem8 Hmem8];
              [simplify_memory_init Hmem2 |].
            destruct (Memory.store_after_load mem8 (Permission.data, C', Block.local, reg_offset E_R_COM)
                                              v7 vcom) as [mem9 Hmem9];
              [simplify_memory_init Hmem2 |].
            destruct (Memory.store_after_load mem9 (Permission.data, C', Block.local, 1%Z)
                                              (Int 1) (Int 0)) as [mem10 Hmem10];
              [simplify_memory_init Hmem2 |].

            exists (ECallInform C P' vcom mem1 regs C').
            exists (StackState C' (C :: callers s)).
            exists [CState C', CS.Frame C arg
                                        (Kassign1 (loc_of_reg E_R_COM)
                                                  (Kseq
                                                     (invalidate_metadata;;
                                                      E_assign EXTCALL (E_val (Int 0));; E_call C P (E_val (Int 0)))
                                                     Kstop
                                        ))
                                        :: stk, mem10,
                Kstop, expr_of_trace C' P' (comp_subtrace C' t), vcom].

            assert (Hstar: star CS.kstep (prepare_global_env p)
                                [CState C, stk, mem, Kstop, E_assign EXTCALL (E_val (Int 1));;
                                                            E_assign (loc_of_reg E_R_COM)
                                                                     (E_call C' P'
                                                                             (E_deref (loc_of_reg E_R_COM)));;
                                                            invalidate_metadata;;
                                                            E_assign EXTCALL (E_val (Int 0));;
                                                            E_call C P (E_val (Int 0)), arg]
                                [:: ECall C P' vcom mem1 C']
                                [CState C', {|
                                              CS.f_component := C;
                                              CS.f_arg := arg;
                                              CS.f_cont := Kassign1 (loc_of_reg E_R_COM)
                                                                    (Kseq
                                                                       (invalidate_metadata;;
                                                                        E_assign EXTCALL (E_val (Int 0));;
                                                                        E_call C P (E_val (Int 0))) Kstop) |}
                                              :: stk, mem10, Kstop, expr_of_trace C' P'
                                                                                 (comp_subtrace C' t), vcom]).
            {
              Local Transparent loc_of_reg.
              take_steps; eauto.
              take_steps; simplify_memory.
              (* do 17 (take_step; eauto). simplify_memory. *)

              eapply star_step. simpl.
              apply CS.eval_kstep_sound. simpl.
              rewrite (negbTE C_ne_C').
              rewrite -> imported_procedure_iff in Himport.
              rewrite <- Hprog_of_trace' at 1.
              rewrite Himport.
              rewrite <- imported_procedure_iff in Himport.
              rewrite <- Hprog_of_trace' at 1. simpl.
              now rewrite (find_procedures_of_trace_exp eprocst (closed_intf Himport)).

              take_step.
              eapply star_trans.
              eapply Star12.
              (* destruct POSTCOND as [POSTCOND1 [POSTCOND2 POSTCOND3]]. *)
              take_steps; eauto. simplify_memory_init Hmem2.
              take_steps. eauto. eauto.
              take_steps. eauto. eauto.
              take_steps. eauto. eauto.
              take_steps. eauto. eauto.
              take_steps. eauto. eauto.
              take_steps. eauto. eauto.
              take_steps. eauto. eauto.
              take_steps. eauto. eauto.
              take_steps.
              eapply star_refl.
              reflexivity.
              reflexivity.
              Local Opaque loc_of_reg.

            }
            assert (wf_cs': well_formed_state_r
                              {| cur_comp := C'; callers := C :: callers s |}
                              (prefix ++ [:: ECallInform (cur_comp s) P' new_arg mem' regs C']) suffix
                              [CState C', {| CS.f_component := C;
                                            CS.f_arg := arg;
                                            CS.f_cont := Kassign1 (loc_of_reg E_R_COM)
                                                                  (Kseq
                                                                     (invalidate_metadata;;
                                                                      E_assign EXTCALL (E_val (Int 0));;
                                                                      E_call C P (E_val (Int 0))) Kstop) |}
                                            :: stk, mem10, Kstop, expr_of_trace C' P'
                                                                               (comp_subtrace C' t), vcom]).
            { econstructor; eauto.
              * destruct wf_stk as (top & bot & ? & Htop & Hbot). subst stk.
                eexists []; eexists; simpl; split; eauto.
                split; [| split]; trivial.
                -- simplify_memory. rewrite -Hmem2'; last congruence.
                   now simplify_memory.
                -- eexists arg, P, top, bot.
                   split; trivial.
                   split; trivial.
                   split; trivial.
                   clear Star0 Star1 Star12 Hstar.
                   elim: (callers s) bot Hbot; trivial.
                   move=> a l IH bot [] H1 H2.
                   fold well_formed_callers in *.
                   split.
                   ++ simplify_memory.
                      destruct (a == C') eqn:eq;
                        move: eq => /eqP eq; subst.
                      simplify_memory.
                      ** now destruct Postcond1.
                      ** rewrite -Hmem2'; last congruence.
                         now simplify_memory.
                   ++ destruct H2 as [? [? [? [? [? [? [? H2]]]]]]].
                      eexists; eexists; eexists; eexists.
                      repeat split; eauto.
              * constructor.
                -- (* wfmem_counter *)
                  move=> C0 C0_b.
                  destruct (C == C0) eqn:Heq;
                    move: Heq => /eqP => Heq; subst; simplify_memory;
                                       [rewrite -Hmem2'; simplify_memory; last congruence|].
                  destruct (C' == C0) eqn:Heq';
                    move: Heq' => /eqP => Heq'; subst; simplify_memory.
                  ++ simplify_memory_init Hmem2.
                     assert (ctr_eq: counter_value C0 ((prefix0 ++ [:: e1]) ++ [:: ECallInform (cur_comp s) P' new_arg mem' regs C0]) =
                                       counter_value C0 (prefix0 ++ [:: e1])).
                     { unfold counter_value, comp_subtrace.
                       rewrite filter_cat. simpl.
                       suff: ((C0 == cur_comp s) = false) => [-> //=|]. rewrite cats0 //=.
                       apply /eqP.
                       unfold C in Heq. congruence. }
                     rewrite ctr_eq. now eapply wfmem_counter.
                  ++ rewrite -Hmem2'; simplify_memory; last congruence.
                     assert (ctr_eq: counter_value C0 ((prefix0 ++ [:: e1]) ++ [:: ECallInform (cur_comp s) P' new_arg mem' regs C']) =
                                       counter_value C0 (prefix0 ++ [:: e1])).
                     { unfold counter_value, comp_subtrace.
                       rewrite filter_cat. simpl.
                       suff: ((C0 == cur_comp s) = false) => [-> //=|]. rewrite cats0 //=.
                       apply /eqP.
                       unfold C in Heq. congruence. }
                     rewrite ctr_eq. now eapply wfmem_counter.
                -- (* wfmem_extcall_ini *)
                  by case prefix.
                -- (* wfmem_extcall *)
                  intros. eapply rcons_inv in H as [? ?]. subst.
                  split.
                  ++ move=> C0 _ //= ?; subst C0.
                     simplify_memory.
                  ++ move=> C0 C0_b //= ?.
                     destruct (C == C0) eqn:Heq;
                       move: Heq => /eqP => Heq; subst; simplify_memory;
                                          [rewrite -Hmem2'; simplify_memory; last congruence|].
                     destruct (C' == C0) eqn:Heq';
                       move: Heq' => /eqP => Heq'; subst; simplify_memory.
                     ** simplify_memory_init Hmem2.
                     ** rewrite -Hmem2'; simplify_memory; last congruence.
                        now eapply wfmem_extcall; eauto; congruence.
                -- (* wfmem_meta *)
                  intros.
                  destruct (C' == C0) eqn:Heq;
                    move: Heq => /eqP => Heq; subst.
                  destruct (wfmem_meta wf_mem E_R_COM H) as [vcom' Hcom'].
                  destruct r; eexists; simplify_memory.
                  match goal with
                  | |- exists v, Memory.load ?mem (Permission.data, ?C, Block.local, reg_offset ?r) = Some v
                    => destruct (wfmem_meta wf_mem r H) as [vr Hvr];
                      destruct r; eexists; simplify_memory;
                      (rewrite -Hmem2'; [simplify_memory | congruence])
                  end.
                -- (* wfmem_ini *)
                  by case prefix.
                -- (* wfmem *)
                  destruct p_gens_t as [s0 Star_s0].
                  move=> es e H; eapply rcons_inv in H as [? ?]; subst.
                  specialize (wfmem wf_mem Logic.eq_refl) as [Hregs [Hnext_comp Hnot_next_comp]].
                  destruct Postcond1 as [Hinitflag2 [Hlocalbuf2 [Hshift2 Hnextblock2]]].
                  (* specialize (wfmem wf_mem Logic.eq_refl) as [Hsnapshot Hregs]. *)
                  assert (Hmem' : mem' = mem_of_event_inform e1). { (* NOTE: In other cases this asser is at the top *)
                    clear -wf_int_pref'.
                    destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                    move: wf_int_pref'; rewrite !cats1 => wf_int_pref.
                    inversion wf_int_pref.
                    - now destruct prefix0.
                    - destruct prefix0. inversion H. simpl in H. now destruct prefix0.
                    - apply rcons_inj in H. inversion H; subst; clear H.
                      apply rcons_inj in H3. inversion H3; subst; clear H3.
                      inversion H1; subst; clear H1.
                      reflexivity. }
                  split; last split.
                  ++ intros reg off Hoffset. simpl.
                     destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                     inversion wf_int_pref' as [| eint Hstep Heint | prefint eint1 eint2 Hsteps Hstep Ht];
                       [now destruct prefix0 | now destruct prefix0 as [| ? []] | ].
                     rewrite cats2 in Ht.
                     apply rcons_inj in Ht. injection Ht as Ht ?; subst eint2.
                     apply rcons_inj in Ht. injection Ht as ? ?; subst prefint eint1.
                     inversion Hstep as [tmp1 tmp2 tmp3 tmp4 tmp5 tmp6 | | | | | | |];
                       subst tmp1 tmp2 tmp3 tmp4 tmp5 tmp6;
                       subst regs.
                     subst new_arg mem' C'0 off.
                     destruct reg;
                       try (eexists; eexists; split; [by simplify_memory' |]; split; reflexivity).
                     destruct (Hregs Machine.R_COM _ Logic.eq_refl) as [vcom'' [vcom' [Hv7' [Hshiftv7 Hgetv7]]]].
                     rewrite -C_next_e1 in Hv7'. simpl in Hvcom, Hv7'. rewrite Hvcom in Hv7'.
                     injection Hv7' as ?; subst vcom''.
                     eexists vcom, vcom'. split; [| split].
                     ** by simplify_memory'.
                     ** eassumption.
                     ** by rewrite Machine.Intermediate.Register.gicom.
                  ++ simpl. intros C0 _ ?; subst C0.
                     split; [| split; [| split]].
                     ** by simplify_memory.
                     ** by simplify_memory.
                     ** intros [| b] Hblock; first contradiction.
                        destruct (Hshift2 _ Hblock) as [[cid bid] [Hshift2' [Hrename2 Hrename2']]].
                        rewrite shift_S_Some in Hshift2'.
                        injection Hshift2' as ? ?; subst cid bid.
                        eexists. split; first reflexivity. split.
                        --- intros off v Hload.
                            repeat (erewrite Memory.load_after_store_neq in Hload;
                                    last eassumption;
                                    last (injection; discriminate)).
                            rewrite /all_zeros_shift /uniform_shift ssrnat.subn1 ssrnat.addn0 /=.
                            specialize (Hrename2 _ _ Hload) as [v' [Hloadv' Hrenamev]].
                            eexists. split; last eassumption.
                            subst mem'.
                            exact Hloadv'.
                        --- rewrite /all_zeros_shift /uniform_shift ssrnat.subn1 ssrnat.addn0 /=.
                            intros off v Hload. subst mem'.
                            specialize (Hrename2' _ _ Hload) as [v' [Hloadv' Hrenamev]].
                            eexists. split; last eassumption.
                            by simplify_memory.
                     ** simpl. intros b Hnextblock.
                        subst mem'.
                        repeat (erewrite Memory.next_block_store_stable;
                                last eassumption).
                        exact (Hnextblock2 _ Hnextblock).
                  ++ simpl. intros C0 C0_b HC0_C'.
                     destruct (Nat.eqb_spec C0 C) as [| HC0_C].
                     ** subst C0.
                        left.
                        specialize (Hnext_comp _ C_b C_next_e1) as Hsteady0.
                        destruct Hsteady0 as [Hinitflag0 [Hlocalbuf0 [Hshift0 Hblock0]]].
                        split; [| split; [| split]].
                        +++ simplify_memory'.
                            erewrite <- Hmem2';
                              last now apply nesym.
                            now simplify_memory'.
                        +++ simplify_memory'.
                            erewrite <- Hmem2';
                              last now apply nesym.
                            now simplify_memory'.
                        +++ intros [| b] Hb; first contradiction.
                            specialize (Hshift0 _ Hb) as [[cid bid] [Hshift0 [Hrename0 Hrename0']]].
                            rewrite shift_S_Some in Hshift0. injection Hshift0 as ? ?; subst cid bid.
                            eexists. split; [| split].
                            *** reflexivity.
                            *** intros off v Hload.
                                repeat
                                  (erewrite Memory.load_after_store_neq in Hload;
                                   last eassumption;
                                   last (injection; discriminate)).
                                erewrite <- Hmem2' in Hload;
                                  last now apply nesym.
                                repeat
                                  (erewrite Memory.load_after_store_neq in Hload;
                                   last eassumption;
                                   last (injection; discriminate)).
                                specialize (Hrename0 _ _ Hload) as [v'' [v' Hshiftv]].
                                eexists. split.
                                ---- rewrite /= /all_zeros_shift /uniform_shift ssrnat.subn1 ssrnat.addn0 /=.
                                     subst mem'. eassumption.
                                ---- eassumption.
                            *** rewrite /= /all_zeros_shift /uniform_shift ssrnat.subn1 ssrnat.addn0 /=.
                                intros off v Hload. subst mem'.
                                specialize (Hrename0' _ _ Hload) as [v'' [v' Hshiftv]].
                                eexists. split.
                                ---- simplify_memory'.
                                     erewrite <- Hmem2';
                                       last now apply nesym.
                                     simplify_memory'. eassumption.
                                ---- eassumption.
                        +++ simpl. intros b Hblock.
                            subst mem'.
                            apply Hblock0 in Hblock.
                            repeat (erewrite Memory.next_block_store_stable;
                                    last eassumption).
                            erewrite <- Hblock2; last congruence.
                            repeat (erewrite Memory.next_block_store_stable;
                                    last eassumption).
                            exact Hblock.
                     ** simpl.
                        rewrite C_next_e1 in HC0_C.
                        specialize (Hnot_next_comp _ C0_b HC0_C) as [Hsteady0 | Hinitial0].
                        --- left.
                            destruct Hsteady0 as [Hinitflag0 [Hlocalbuf0 [Hshift0 Hblock0]]].
                            split; [| split; [| split]].
                            +++ simplify_memory'.
                                erewrite <- Hmem2';
                                  last (intros ?; subst C0; contradiction).
                                now simplify_memory'.
                            +++ simplify_memory'.
                                erewrite <- Hmem2';
                                  last (intros ?; subst C0; contradiction).
                                now simplify_memory'.
                            +++ intros [| b] Hb; first contradiction.
                                specialize (Hshift0 _ Hb) as [[cid bid] [Hshift0 [Hrename0 Hrename0']]].
                                rewrite shift_S_Some in Hshift0. injection Hshift0 as ? ?; subst cid bid.
                                eexists. split; [| split].
                                *** reflexivity.
                                *** intros off v Hload.
                                    repeat
                                      (erewrite Memory.load_after_store_neq in Hload;
                                       last eassumption;
                                       last (injection; discriminate)).
                                    erewrite <- Hmem2' in Hload;
                                      last (simpl; intros ?; subst C0; contradiction).
                                    repeat
                                      (erewrite Memory.load_after_store_neq in Hload;
                                       last eassumption;
                                       last (injection; discriminate)).
                                    specialize (Hrename0 _ _ Hload) as [v'' [v' Hshiftv]].
                                    eexists. split.
                                    ---- rewrite /= /all_zeros_shift /uniform_shift ssrnat.subn1 ssrnat.addn0 /=.
                                         subst mem'. eassumption.
                                    ---- eassumption.
                                *** rewrite /= /all_zeros_shift /uniform_shift ssrnat.subn1 ssrnat.addn0 /=.
                                    intros off v Hload. subst mem'.
                                    specialize (Hrename0' _ _ Hload) as [v'' [v' Hshiftv]].
                                    eexists. split.
                                    ---- simplify_memory'.
                                         erewrite <- Hmem2';
                                           last (intros ?; subst C0; contradiction).
                                         simplify_memory'. eassumption.
                                    ---- eassumption.
                            +++ simpl. intros b Hblock.
                                subst mem'.
                                apply Hblock0 in Hblock.
                                repeat (erewrite Memory.next_block_store_stable;
                                        last eassumption).
                                erewrite <- Hblock2; last congruence.
                                repeat (erewrite Memory.next_block_store_stable;
                                        last eassumption).
                                exact Hblock.
                        --- right.
                            destruct Hinitial0 as [Hinitflag0 [Hlocalbuf0 [Hprealloc0 Hnot_shared0]]].
                            split; [| split; [| split; [split |]]].
                            +++ simplify_memory'.
                                erewrite <- Hmem2';
                                  last (intros ?; subst C0; contradiction).
                                now simplify_memory'.
                            +++ simplify_memory'.
                                erewrite <- Hmem2';
                                  last (intros ?; subst C0; contradiction).
                                now simplify_memory'.
                            +++ destruct Hprealloc0 as [[Cmem0 [buf [HCmem0 [Hbuf [Hnext0 Hprealloc]]]]] _].
                                subst Cmem0.
                                eexists. eexists.
                                split; [| split; [| split]];
                                  last reflexivity; try eassumption.
                                simpl. now rewrite Hmem' HCmem0.
                            +++ destruct Hprealloc0 as [_ Hblock0].
                                destruct Hblock0 as [Cmem0 [HCmem0 Hblock0]].
                                exists Cmem0. split.
                                *** repeat
                                    (erewrite <- Memory.component_memory_after_store_neq;
                                     [| eassumption |];
                                     last (simpl; intros ?; subst C'; rewrite /C //= in C_ne_C')).
                                    assert (Hrewr : mem1 C0 = mem2 C0). {
                                    apply initialization_correct_component_memory.
                                    - intros b off. apply Hmem2'; now auto.
                                    - apply Hblock2; now auto.
                                    - erewrite Memory.next_block_store_stable;
                                        last now eauto.
                                      erewrite Memory.next_block_store_stable;
                                        last now eauto.
                                      now rewrite /Memory.next_block HCmem0 Hblock0.
                                    - exists LOCALBUF_offset, Undef. now simplify_memory. }
                                  rewrite -Hrewr.
                                    repeat (erewrite <- Memory.component_memory_after_store_neq;
                                            [| eassumption |];
                                            last (simpl; congruence)).
                                    exact HCmem0.
                                *** exact Hblock0.
                            +++
                              intros b Hb.
                              (* destruct p_gens_t as [s0 Star_s0]. *)
                              (* unfold CSInvariants.CSInvariants.is_prefix in Star_s0. *)
                              rewrite project_non_inform_append !cats1 in Star_s0.
                              setoid_rewrite project_non_inform_append in Star_s0.
                              setoid_rewrite app_assoc in Star_s0.
                              apply star_app_inv in Star_s0 as [s0' [star_s0' star_s0]].
                              simpl in star_s0'. setoid_rewrite cats1 in star_s0'.
                              eapply CSInvariants.CSInvariants.not_shared_diff_comp_not_shared_call
                                with (Cb := C0). exact wf_p_interm. exact closed_p_interm.
                              exact star_s0'.
                              rewrite -C_next_e1 in HC0_C. unfold C in HC0_C. eauto.
                              eauto.
                              rewrite -cats1 project_non_inform_append cats1 in Hb.
                              setoid_rewrite cats1 in Hb. eauto.
                              apply CS.CS.singleton_traces_non_inform.
                -- move=> ptr cid bid off.
                   destruct (Pointer.eq ptr (Permission.data, C', Block.local, 1%Z)) eqn:eq_ptr;
                     move: eq_ptr =>
                              /Pointer.eqP eq_ptr; subst;
                              [erewrite (Memory.load_after_store_eq _ _ _ _ Hmem10); eauto; try by []
                              | erewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem10); eauto; clear eq_ptr].
                   destruct (Pointer.eq ptr (Permission.data, C', Block.local, reg_offset E_R_COM)) eqn:eq_ptr;
                     move: eq_ptr =>
                              /Pointer.eqP eq_ptr; subst;
                              [erewrite (Memory.load_after_store_eq _ _ _ _ Hmem9); eauto; try by []
                              | erewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem9); eauto; clear eq_ptr].
                   specialize (steady_C1 Machine.R_COM _ Logic.eq_refl) as [v1' [v2' G]].
                   destruct G as [G1 [G2 G3]].
                   rewrite -C_next_e1 in G1. rewrite G1 in Hvcom. inversion Hvcom; subst; clear Hvcom.
                   destruct vcom as [| [[[[]]]] |]; try discriminate.
                   rewrite /all_zeros_shift /uniform_shift //=
                           /rename_addr_option /sigma_shifting_wrap_bid_in_addr
                           /sigma_shifting_lefttoright_addr_bid
                           /sigma_shifting_lefttoright_option in G2.
                   destruct i0; try discriminate. simpl in G2. intros R; inversion R; by [].
                   destruct (Pointer.eq ptr (Permission.data, C', Block.local, reg_offset E_R_ARG)) eqn:eq_ptr;
                     move: eq_ptr =>
                              /Pointer.eqP eq_ptr; subst;
                              [erewrite (Memory.load_after_store_eq _ _ _ _ Hmem8); eauto; try by []
                              | erewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem8); eauto; clear eq_ptr].
                   destruct (Pointer.eq ptr (Permission.data, C', Block.local, reg_offset E_R_SP)) eqn:eq_ptr;
                     move: eq_ptr =>
                              /Pointer.eqP eq_ptr; subst;
                              [erewrite (Memory.load_after_store_eq _ _ _ _ Hmem7); eauto; try by []
                              | erewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem7); eauto; clear eq_ptr].
                   destruct (Pointer.eq ptr (Permission.data, C', Block.local, reg_offset E_R_RA)) eqn:eq_ptr;
                     move: eq_ptr =>
                              /Pointer.eqP eq_ptr; subst;
                              [erewrite (Memory.load_after_store_eq _ _ _ _ Hmem6); eauto; try by []
                              | erewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem6); eauto; clear eq_ptr].
                   destruct (Pointer.eq ptr (Permission.data, C', Block.local, reg_offset E_R_AUX2)) eqn:eq_ptr;
                     move: eq_ptr =>
                              /Pointer.eqP eq_ptr; subst;
                              [erewrite (Memory.load_after_store_eq _ _ _ _ Hmem5); eauto; try by []
                              | erewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem5); eauto; clear eq_ptr].
                   destruct (Pointer.eq ptr (Permission.data, C', Block.local, reg_offset E_R_AUX1)) eqn:eq_ptr;
                     move: eq_ptr =>
                              /Pointer.eqP eq_ptr; subst;
                              [erewrite (Memory.load_after_store_eq _ _ _ _ Hmem4); eauto; try by []
                              | erewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem4); eauto; clear eq_ptr].
                   destruct (Pointer.eq ptr (Permission.data, C', Block.local, reg_offset E_R_ONE)) eqn:eq_ptr;
                     move: eq_ptr =>
                              /Pointer.eqP eq_ptr; subst;
                              [erewrite (Memory.load_after_store_eq _ _ _ _ Hmem3); eauto; try by []
                              | erewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem3); eauto; clear eq_ptr].
              * right. left. by apply: (closed_intf Himport). }

            split; last split.
            + eauto.
            + exact wf_cs'.
            + { rewrite project_non_inform_append. simpl.
                replace (project_non_inform prefix ** [:: ECall (cur_comp s) P' new_arg mem' C'])
                  with (project_non_inform prefix ++ [:: ECall (cur_comp s) P' new_arg mem' C']); last by reflexivity.
                rewrite 2!cats1.
                eapply rcons_renames_rcons_option; eauto.
                - inversion Hshift; eauto.
                - intros [Cb b] Hshared.
                  split.
                  + rewrite /all_zeros_shift /uniform_shift
                            /event_renames_event_at_shared_addr //=.
                    (* destruct cs'.simpl in mem_cs'; subst s_memory. *)
                    (* MARK 2 *)
                    inversion wf_cs' as [? ? ? ? ? ? ? ? ? ? ? ? ? ? wf_mem10 ?].
                    subst C0 stk0 mem11 arg0 k exp.
                    eapply wfmem in wf_mem10 as [wf_regs [wf_mem10 wf_mem10']];
                      last reflexivity.
                    simpl in wf_regs, wf_mem10, wf_mem10'.
                    unfold postcondition_steady_state in wf_mem10.
                    unfold postcondition_event_snapshot_steadystate in wf_mem10.
                    case Cb_C: (Cb == C'); move: Cb_C => /eqP Cb_C; [subst Cb |].
                    * specialize (wf_mem10 _ C'_b Logic.eq_refl) as [_ [_ [Hshift1 _]]].
                      unfold well_formed_memory_snapshot_steadystate_shift in Hshift1.
                      unfold memory_shifts_memory_at_shared_addr in Hshift1.
                      unfold all_zeros_shift, uniform_shift in Hshift1.
                      simpl in Hshift1.
                      specialize (Hshift1 (S b)).
                      unfold memory_renames_memory_at_shared_addr in *.
                      eexists (C', S b).
                      split; [| split].
                      -- rewrite /sigma_shifting_wrap_bid_in_addr. simpl.
                         by rewrite ssrnat.subn0 ssrnat.addn1.
                      -- intros off v Hload; simpl in *.
                         destruct Hshift1 as [addr' [Hshift1 [Hshift2 Hshift3]]];
                           first easy.
                         rewrite /sigma_shifting_wrap_bid_in_addr //= in Hshift1.
                         rewrite ssrnat.subn1 ssrnat.addn0 in Hshift1.
                         inversion Hshift1; subst addr'.
                         simpl in Hshift3.
                         specialize (Hshift3 _ _ Hload) as [? [? ?]].
                         destruct steady_C3'' as [Hsteady | Huninit].
                         {
                           eexists; split.
                           ++ repeat match goal with
                                     | Hload: Memory.load ?mem' ?ptr' = Some ?v',
                                         Hstore: Memory.store ?mem ?ptr ?v = Some ?mem' |- _ =>
                                         erewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hstore) in Hload
                                     end.

                              rewrite Hsteady_localbuf2; eauto.
                           ++ destruct x; simpl in *; try by inversion H7; subst v.
                              destruct t0 as [[[[|] ?] ?] ?]; simpl in *.
                              by inversion H7.
                              destruct i0; inversion H7; subst v.
                              by rewrite //= ssrnat.subn1 ssrnat.addn0 ssrnat.subn0 ssrnat.addn1.
                         }
                         {
                           destruct p_gens_t as [? G].
                           rewrite Et project_non_inform_append in G.
                           simpl in G. unfold Eapp in G.
                           replace ((ECall (cur_comp s) P' new_arg mem' C' :: project_non_inform suffix)) with ([:: ECall (cur_comp s) P' new_arg mem' C'] ++ project_non_inform suffix) in G; last reflexivity.
                           setoid_rewrite app_assoc in G.
                           apply star_app_inv in G as [? [G _]].
                           setoid_rewrite cats1 in G.

                           eapply CSInvariants.CSInvariants.not_executing_can_not_share in
                             Hshared; eauto; first contradiction.
                           + move : C_ne_C' => /eqP => ?. by auto.
                           + rewrite Hprefix01 cats1. by destruct Huninit as [? [? [? ?]]].
                           + apply CS.CS.singleton_traces_non_inform.
                         }
                      -- intros off v Hload; simpl in *.
                         destruct Hshift1 as [addr' [Hshift1 [Hshift2 Hshift3]]];
                           first easy.
                         rewrite /sigma_shifting_wrap_bid_in_addr //= in Hshift1.
                         rewrite ssrnat.subn1 ssrnat.addn0 in Hshift1.
                         inversion Hshift1; subst addr'.
                         simpl in Hshift2.
                         (* *)
                         destruct steady_C3'' as [Hsteady | Huninit].
                         {
                           repeat match goal with
                                  | Hload: Memory.load ?mem' ?ptr' = Some ?v',
                                      Hstore: Memory.store ?mem ?ptr ?v = Some ?mem' |- _ =>
                                      erewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hstore) in Hload
                                  end.
                           assert (Hload': Memory.load mem10 (Permission.data, C', S b, off) = Some v).
                           { simplify_memory.
                             rewrite -Hsteady_localbuf2; eauto.
                             simplify_memory.
                           }
                           specialize (Hshift2 _ _ Hload') as [v' [G Hv']].

                           eexists; split; first eassumption.
                           destruct v; simpl in *; try by inversion Hv'; subst.
                           destruct t0 as [[[[|] ?] ?] ?]; simpl in *; first by inversion Hv'.
                           destruct i0; inversion Hv'; subst.
                           by rewrite //= ssrnat.subn1 ssrnat.addn0 ssrnat.subn0 ssrnat.addn1.
                         }
                         {
                           destruct p_gens_t as [? G].
                           rewrite Et project_non_inform_append in G.
                           simpl in G. unfold Eapp in G.
                           replace ((ECall (cur_comp s) P' new_arg mem' C' :: project_non_inform suffix)) with ([:: ECall (cur_comp s) P' new_arg mem' C'] ++ project_non_inform suffix) in G; last reflexivity.
                           setoid_rewrite app_assoc in G.
                           apply star_app_inv in G as [? [G _]].
                           setoid_rewrite cats1 in G.

                           eapply CSInvariants.CSInvariants.not_executing_can_not_share in
                             Hshared; eauto; first contradiction.
                           + move : C_ne_C' => /eqP => ?. by auto.
                           + rewrite Hprefix01 cats1. by destruct Huninit as [? [? [? ?]]].
                           + apply CS.CS.singleton_traces_non_inform.
                         }

                    * (* Prove good_trace something. Get from Hshared that there's a
                       * load and [1 <= b]. Now we can get a contradiction to
                       * [postcondition_uninitialized] *)
                      (* *)
                      exists (Cb, S b).
                      split.
                      -- rewrite /all_zeros_shift /uniform_shift //=.
                         rewrite /sigma_shifting_wrap_bid_in_addr //=.
                         by rewrite ssrnat.subn0 ssrnat.addn1.
                      -- assert (Hwf_p: Source.well_formed_program p).
                         {
                           eapply well_formed_events_well_formed_program
                             in wf_events as [? [? ?]]; eauto.
                           + erewrite Hprog_of_trace in H6. inversion H6.
                             by subst x.
                           + by eapply domm_t_procs_exported_procedures_of_trace.
                         }
                         assert (Hclosed_p: Source.closed_program p).
                         {
                           by eapply closed_program_of_trace; eauto.
                         }
                         split; intros ? ? Hload.
                         ++ simpl in *.
                            assert (HCb: component_buffer Cb).
                            {
                              (** This essentially follows IF we knew that the
                          intermediate trace came from an intermediate execution.
                          Then, we can possibly use a lemma in CSInvariants? *)

                              unfold component_buffer.
                              replace intf with (Machine.Intermediate.prog_interface p_interm).
                              destruct p_gens_t as [? G].
                              rewrite Et project_non_inform_append in G.
                              simpl in G. unfold Eapp in G.
                              replace ((ECall (cur_comp s) P' new_arg mem' C' :: project_non_inform suffix)) with ([:: ECall (cur_comp s) P' new_arg mem' C'] ++ project_non_inform suffix) in G; last reflexivity.
                              setoid_rewrite app_assoc in G.
                              apply star_app_inv in G as [? [G _]].
                              setoid_rewrite cats1 in G.
                              eapply CSInvariants.CSInvariants.load_Some_component_buffer with
                                (ptr := (Permission.data, Cb, b, offset))
                                (e := (ECall (cur_comp s) P' new_arg mem' C')); eauto.
                              apply CS.CS.singleton_traces_non_inform.
                            }
                            specialize (wf_mem10' _ HCb Cb_C) as
                              [[? [? [? ?]]] | [? [? [[[compMem [? HcompMem]] ?] Hnot_shared]]] ].
                            ** assert (Hnoteq: S b <> Block.local).
                               { by unfold Block.local. }
                               specialize (steadysnap_shift0 _ Hnoteq)
                                 as [[C_ b_] [Hb_ [mem10_mem' mem'_mem10]]].
                               rewrite shift_S_Some in Hb_.
                               inversion Hb_; subst C_ b_; clear Hb_.
                               simpl in *.
                               specialize (mem'_mem10 _ _ Hload) as [v' [Hloadv' Hv']].
                               exists v'. split.
                               --- simplify_memory_in_assm. rewrite Hmem2'; eauto.
                               --- specialize (shift_value_option_symmetry
                                                 (fun=> 1) (fun=> 0)) as Lem.
                                   unfold shift_value_option,
                                     sigma_shifting_wrap_bid_in_addr,
                                     sigma_shifting_lefttoright_addr_bid,
                                     rename_addr_option in *.
                                   by eapply Lem.
                            ** simpl in *. destruct HcompMem as [HcompMem [? [Hnext ?]]].
                               (** Intuitively, there should be a contradiction. *)
                               (** In particular, ** is the case where Cb is not *)
                               (** initialized. What we know about Cb is that it *)
                               (** shared an address and that this address also was *)
                               (** loaded from memory (Hload). *)
                               specialize (Hnot_shared b).
                               rewrite -!cats1 project_non_inform_append /= in Hnot_shared.
                               setoid_rewrite cats1 in Hnot_shared.
                               apply Hnot_shared in Hshared.
                               contradiction.
                         ++ simpl in *.
                            assert (Hload': Memory.load
                                              mem10
                                              (Permission.data, Cb, S b, offset) = Some v').
                            { simplify_memory. rewrite -Hmem2'. eauto. eauto. }
                            (** Need to know component_buffer Cb. *)
                            (** Intuitively, we should know it from Hload *)
                            (** Knowing it from Hload should be a source "CSInvariant". *)

                            assert (HCb: component_buffer Cb).
                            {
                              unfold component_buffer.
                              replace intf with (Machine.Intermediate.prog_interface p_interm).

                              assert (starG : star CS.kstep (prepare_global_env p) (CS.initial_machine_state p)
                                                   (rcons (project_non_inform prefix_inform) (ECall (cur_comp s) P' vcom mem1 C'))

                                                   [CState C', {|
                                                                 CS.f_component := C;
                                                                 CS.f_arg := arg;
                                                                 CS.f_cont := Kassign1 (loc_of_reg E_R_COM)
                                                                                       (Kseq
                                                                                          (invalidate_metadata;;
                                                                                           E_assign EXTCALL (E_val (Int 0));;
                                                                                           E_call C P (E_val (Int 0))) Kstop) |} :: stk, mem10, Kstop,
                                                     expr_of_trace C' P' (comp_subtrace C' t), vcom]
                                     ).
                              {
                                rewrite -cats1.
                                eapply star_trans; eauto.
                                - eapply star_trans; eauto.
                                - simpl. subst. by unfold C.
                              }
                              specialize (@CS.CS.load_component_prog_interface_addr
                                            _ Hwf_p Hclosed_p _ _ _
                                            (Permission.data, Cb, S b, offset) v'
                                            Logic.eq_refl starG
                                         ) as G'.
                              simpl in *. rewrite p_interm_intf.
                              subst p. simpl in *.
                              eapply G'; eauto.
                            }

                            specialize (wf_mem10' _ HCb Cb_C) as
                              [[? [? [? ?]]] | [? [? [[[compMem [? HcompMem]] ?] Hnot_shared]]] ].
                            ** assert (Hnoteq: S b <> Block.local).
                               { by unfold Block.local. }
                               specialize (steadysnap_shift0 _ Hnoteq)
                                 as [[C_ b_] [Hb_ [mem10_mem' mem'_mem10]]].
                               rewrite shift_S_Some in Hb_.
                               inversion Hb_; subst C_ b_; clear Hb_.
                               simpl in *.
                               specialize (mem10_mem' _ _ Hload') as [v'' [Hloadv' Hv']].
                               exists v''. split.
                               --- assumption.
                               --- specialize (shift_value_option_symmetry
                                                 (fun=> 1) (fun=> 0)) as Lem.
                                   unfold shift_value_option,
                                     sigma_shifting_wrap_bid_in_addr,
                                     sigma_shifting_lefttoright_addr_bid,
                                     rename_addr_option in *.
                                   by eapply Lem.
                            ** simpl in HcompMem.
                               destruct H8 as [src_compMem [Hsrc_compMem Hnextblock]].
                               assert (Memory.next_block mem10 Cb = Some LOCALBUF_blockid).
                               unfold Memory.next_block; rewrite Hsrc_compMem Hnextblock //=.
                               replace Cb with
                                 (Pointer.component (Permission.data, Cb, S b, offset)) in H8 by reflexivity.
                               apply Memory.load_next_block_None in H8. congruence.
                               simpl. unfold LOCALBUF_blockid. apply /ssrnat.leP. lia.

                  + exists (Cb, S b).
                    split.
                    * rewrite /all_zeros_shift /uniform_shift //=.
                      rewrite /sigma_shifting_wrap_bid_in_addr //=.
                      by rewrite ssrnat.subn0 ssrnat.addn1.
                    * inversion wf_cs' as [? ? ? ? ? ? ? ? ? ? ? ? ? ? wf_mem8 ?].
                      subst.
                      eapply wfmem in wf_mem8 as [wf_regs [wf_mem8 wf_mem8']];
                        last reflexivity.
                      eapply addr_shared_so_far_inv_1 with (mem := mem0); eauto.
                      -- intros. by simplify_memory'.
                      -- simpl.
                         unfold all_zeros_shift, uniform_shift.
                         destruct (wf_regs Machine.R_COM _ Logic.eq_refl) as [vcom' [newarg' [G1 [G2 G3]]]].
                         simpl in *.
                         assert (vcom' = vcom).
                         { rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem10) in G1; last congruence.
                           rewrite (Memory.load_after_store_eq _ _ _ _ Hmem9) in G1; congruence. } subst vcom'.
                         assert (newarg' = new_arg).
                         { apply ipref_evsteps in wf_int_pref'.
                           rewrite cats1 in wf_int_pref'.
                           inversion wf_int_pref'. now destruct prefix0.
                           destruct prefix0. simpl in *. congruence.
                           now destruct prefix0.
                           find_rcons_rcons. inversion H8; subst; eauto.
                         } subst.
                         auto.
                      -- eapply wfmem in wf_mem; last reflexivity.
                         destruct wf_mem as [_ [wf_mem _]].
                         intros; subst; simpl in *.
                         unfold postcondition_steady_state, postcondition_event_snapshot_steadystate in wf_mem.
                         specialize (wf_mem _ C_b C_next_e1) as [_ [_ [G _]]].
                         intros [| b'] not_local; first (unfold Block.local in not_local; congruence).
                         specialize (G _ not_local). destruct G as [addr [G1 [G2 G3]]].
                         eexists; split; last split; eauto.
                         ++ intros offset v Hload.
                            specialize (G2 _ _ Hload) as [v' [Hload' Hren]].
                            inversion wf_int_pref' as [U1 U2].
                            rewrite !cats1 in U1.
                            inversion U1.
                            ** now destruct prefix0.
                            ** now destruct prefix0 as [| ? []].
                            ** find_rcons_rcons. find_rcons_rcons.
                               inversion H9; subst; clear H9. eauto.
                         ++ intros offset v Hload.
                            inversion wf_int_pref' as [U1 U2].
                            rewrite !cats1 in U1.
                            inversion U1.
                            ** now destruct prefix0.
                            ** now destruct prefix0 as [| ? []].
                            ** find_rcons_rcons. find_rcons_rcons.
                               inversion H9; subst; clear H9. eauto.
                      -- eapply wfmem in wf_mem; last reflexivity.
                         destruct wf_mem as [_ [wf_mem1 wf_mem2]].
                         intros C0 C0_b.
                         destruct (C0 == next_comp_of_event e1) eqn:eC0;
                           move: eC0 => /eqP eC0; subst.
                         ++ left.
                            specialize (wf_mem1 _ C0_b Logic.eq_refl) as [_ [_ [G _]]].
                            { intros [| b'] not_local; first (unfold Block.local in not_local; congruence).
                              specialize (G _ not_local). destruct G as [addr [G1 [G2 G3]]].
                              eexists; split; last split; eauto.
                              ++ intros offset v Hload.
                                 specialize (G2 _ _ Hload) as [v' [Hload' Hren]].
                                 inversion wf_int_pref' as [U1 U2].
                                 rewrite !cats1 in U1.
                                 inversion U1.
                                 ** now destruct prefix0.
                                 ** now destruct prefix0 as [| ? []].
                                 ** find_rcons_rcons. find_rcons_rcons.
                                    inversion H8; subst; clear H8. eauto.
                              ++ intros offset v Hload.
                                 inversion wf_int_pref' as [U1 U2].
                                 rewrite !cats1 in U1.
                                 inversion U1.
                                 ** now destruct prefix0.
                                 ** now destruct prefix0 as [| ? []].
                                 ** find_rcons_rcons. find_rcons_rcons.
                                    inversion H8; subst; clear H8. eauto. }
                         ++ specialize (wf_mem2 C0 C0_b eC0) as [wf_mem2 | wf_mem2].
                            ** left. destruct wf_mem2 as [_ [_ [G _]]].
                               { intros [| b'] not_local; first (unfold Block.local in not_local; congruence).
                                 specialize (G _ not_local). destruct G as [addr [G1 [G2 G3]]].
                                 eexists; split; last split; eauto.
                                 ++ intros offset v Hload.
                                    specialize (G2 _ _ Hload) as [v' [Hload' Hren]].
                                    inversion wf_int_pref' as [U1 U2].
                                    rewrite !cats1 in U1.
                                    inversion U1.
                                    ** now destruct prefix0.
                                    ** now destruct prefix0 as [| ? []].
                                    ** find_rcons_rcons. find_rcons_rcons.
                                       inversion H8; subst; clear H8. eauto.
                                 ++ intros offset v Hload.
                                    inversion wf_int_pref' as [U1 U2].
                                    rewrite !cats1 in U1.
                                    inversion U1.
                                    ** now destruct prefix0.
                                    ** now destruct prefix0 as [| ? []].
                                    ** find_rcons_rcons. find_rcons_rcons.
                                       inversion H8; subst; clear H8. eauto. }
                            ** right.
                               destruct wf_mem2 as [_ [_ [_ G]]].
                               now rewrite cats1.
                      -- intros C0 b0 C0_b not_eq not_shared shared.
                         assert (inv_mem: CSInvariants.CSInvariants.wf_mem_wrt_t_pc
                                            (mem_of_event_inform e1)
                                            (project_non_inform (prefix0 ++ [:: e1]))
                                            C).
                         { destruct p_gens_t_inform as [x star].
                           rewrite Et in star.
                           eapply star_app_inv in star as [x0 [star1 _]];
                             last eapply CS.CS.singleton_traces_inform.
                           eapply CSInvariants.CSInvariants.wf_state_wf_mem; eauto.
                           eapply CSInvariants.CSInvariants.is_prefix_wf_state_t; eauto.
                           eapply CS.CS.star_sem_inform_star_sem_non_inform. eauto.
                           erewrite CS.CS.starR_memory_of_event_inform; first by reflexivity.
                           eapply star_iff_starR. rewrite cats1 in star1. simpl in star1. eauto.
                           erewrite <- CS.CS.starR_next_comp_of_event_inform. eauto.
                           eapply star_iff_starR. rewrite cats1 in star1. simpl in star1. eauto. }
                         assert (inv_regs: CSInvariants.CSInvariants.wf_reg_wrt_t_pc
                                             (register_file_of_event_inform e1)
                                             (project_non_inform (prefix0 ++ [:: e1]))
                                             C).
                         { destruct p_gens_t_inform as [x star].
                           rewrite Et in star.
                           eapply star_app_inv in star as [x0 [star1 _]];
                             last eapply CS.CS.singleton_traces_inform.
                           eapply CSInvariants.CSInvariants.wf_state_wf_reg; eauto.
                           eapply CSInvariants.CSInvariants.is_prefix_wf_state_t; eauto.
                           eapply CS.CS.star_sem_inform_star_sem_non_inform. eauto.
                           erewrite CS.CS.starR_register_file_of_event_inform; first by reflexivity.
                           eapply star_iff_starR. rewrite cats1 in star1. simpl in star1. eauto.
                           erewrite <- CS.CS.starR_next_comp_of_event_inform. eauto.
                           eapply star_iff_starR. rewrite cats1 in star1. simpl in star1. eauto. }
                         clear -inv_mem inv_regs shared not_shared not_eq wf_int_pref'.
                         inversion shared; subst; clear shared.
                         ++ find_rcons_rcons. simpl in H1.
                            remember (C0, b0) as addr.
                            rewrite -Heqaddr in H1.
                            remember (addr_of_value new_arg) as addr_set.
                            generalize dependent b0. generalize dependent C0. generalize dependent new_arg.
                            induction H1.
                            ** intros new_arg wf_int_pref' eq_addr_set C0 C0_cur b0 eq_addr; subst.
                               simpl in H. destruct new_arg as [| [[[[]]]] |]; try discriminate.
                               simpl in H. rewrite in_fset1 in H.
                               move: H => /eqP H. inversion H; subst; clear H.
                               unfold CSInvariants.CSInvariants.wf_reg_wrt_t_pc in inv_regs.
                               inversion wf_int_pref' as [U1 _].
                               rewrite !cats1 in U1.
                               inversion U1.
                               --- now destruct prefix0.
                               --- now destruct prefix0 as [| ? []].
                               --- find_rcons_rcons. find_rcons_rcons.
                                   inversion H1; subst; clear H1. simpl in *.
                                   specialize (inv_regs _ _ H11 Logic.eq_refl).
                                   inversion inv_regs; subst; clear inv_regs.
                                   +++ unfold C in C0_cur. contradiction.
                                   +++ contradiction.
                            ** intros new_arg wf_int_pref' eq_addr_set C0 C0_cur b0 eq_addr; subst.
                               apply In_in in H0.
                               apply ComponentMemory.load_block_load in H0 as [? [i Hload']].
                               assert (Hload: Memory.load mem' (Permission.data, cid, bid, i) =
                                                Some (Ptr (Permission.data, C0, b0, x))).
                               { Local Transparent Memory.load.
                                 unfold Memory.load. simpl. rewrite H. assumption.
                                 Local Opaque Memory.load. }
                               inversion wf_int_pref' as [U1 _].
                               rewrite !cats1 in U1.
                               inversion U1.
                               --- now destruct prefix0.
                               --- now destruct prefix0 as [| ? []].
                               --- find_rcons_rcons. find_rcons_rcons.
                                   inversion H3; subst; clear H3. simpl in *.
                                   specialize (inv_mem _ _ Hload Logic.eq_refl).
                                   inversion inv_mem; subst; clear inv_mem.
                                   (* CSInvariants.CSInvariants.wf_load *)
                                   +++ simpl in *. subst.
                                       specialize (IHReachable H3 _ wf_int_pref').
                                       eapply IHReachable; eauto.
                                   +++ simpl in *. subst. contradiction.
                                   +++ simpl in *. subst. contradiction.
                         ++ find_rcons_rcons. simpl in H2.
                            remember (C0, b0) as addr.
                            rewrite -Heqaddr in H2.
                            remember (fset1 addr') as addr_set.
                            generalize dependent b0. generalize dependent C0. generalize dependent addr'.
                            induction H2.
                            ** intros addr' shared eq_addr_set C0 C0_cur b0 eq_addr; subst.
                               simpl in H. destruct addr' as [cid bid].
                               simpl in H. rewrite in_fset1 in H.
                               move: H => /eqP H. inversion H; subst; clear H.
                               contradiction.
                            ** intros addr' shared eq_addr_set C0 C0_cur b0 eq_addr; subst.
                               apply In_in in H0.
                               apply ComponentMemory.load_block_load in H0 as [? [i Hload']].
                               assert (Hload: Memory.load mem' (Permission.data, cid, bid, i) =
                                                Some (Ptr (Permission.data, C0, b0, x))).
                               { Local Transparent Memory.load.
                                 unfold Memory.load. simpl. rewrite H. assumption.
                                 Local Opaque Memory.load. }
                               inversion wf_int_pref' as [U1 _].
                               rewrite !cats1 in U1.
                               inversion U1.
                               --- now destruct prefix0.
                               --- now destruct prefix0 as [| ? []].
                               --- find_rcons_rcons. find_rcons_rcons.
                                   inversion H3; subst; clear H3. simpl in *.
                                   specialize (inv_mem _ _ Hload Logic.eq_refl).
                                   inversion inv_mem; subst; clear inv_mem.
                                   (* CSInvariants.CSInvariants.wf_load *)
                                   +++ simpl in *. subst.
                                       eapply IHReachable; eauto.
                                   +++ simpl in *. subst. contradiction.
                                   +++ simpl in *. subst. contradiction.
                      -- intros C0 b0 o v Hload. unfold component_buffer.
                         (* Use p_interm and p_gens_t. *)
                         (* and (CS.CS.comes_from_initial_state_mem_domm _ intf). *)
                         destruct p_gens_t_inform as [x star].
                         rewrite Et in star.
                         eapply star_app_inv in star as [x0 [star1 _]];
                           last eapply CS.CS.singleton_traces_inform.

                         rewrite <- (CS.CS.comes_from_initial_state_mem_domm x0 intf); eauto.
                         Local Transparent Memory.load.
                         unfold Memory.load in Hload. simpl in Hload.
                         destruct (mem' C0) eqn:mem'_C0; last discriminate.
                         erewrite <- CS.CS.starR_memory_of_event_inform.
                         inversion wf_int_pref' as [U1 _].
                         rewrite !cats1 in U1.
                         inversion U1.
                         --- now destruct prefix0.
                         --- now destruct prefix0 as [| ? []].
                         --- find_rcons_rcons. find_rcons_rcons.
                             inversion H8; subst; clear H8. simpl in *.
                             apply /dommP. eexists; eauto.
                         --- eapply star_iff_starR. rewrite cats1 in star1. simpl in star1. eauto.
                         --- unfold CS.CS.comes_from_initial_state.
                             eapply Machine.Intermediate.cprog_main_existence in closed_p_interm as [? [? ?]].
                             eexists; eexists; eexists; split. eauto.
                             split; eauto.
                             split; eauto.
                             split; eauto. reflexivity.
                      -- eapply traces_rename_each_other_option_symmetric. reflexivity.
                         inversion Hshift; eauto.
                - intros [Cb b] Hshared.

                  destruct b.
                  ++ exfalso.
                     assert (load_in_intf: forall ptr v,
                                Memory.load mem0 ptr = Some v ->
                                Pointer.component ptr \in domm intf).
                     { eapply CS.comes_from_initial_state_mem_domm in Star0; eauto.
                       - subst p. simpl in Star0.  rewrite <- Star0.
                         now eapply CS.load_some_in_domm.
                       - eapply well_formed_events_well_formed_program
                           in wf_events as [p_wf [Hp_wf1 Hp_wf2]]; eauto.
                         + erewrite Hprog_of_trace in Hp_wf1. inversion Hp_wf1.
                           by subst p_wf.
                         + by eapply domm_t_procs_exported_procedures_of_trace.
                       - eapply closed_program_of_trace.
                         subst p. by erewrite Hprog_of_trace.
                       - reflexivity. }
                     inversion Hshared; subst; clear Hshared.
                     { find_rcons_rcons. simpl in H1.
                       clear -wf_mem Hmem Hmem1 wf_int_pref' Hvcom H1 C_next_e1 C_b load_in_intf.
                       remember (Cb, 0) as addr. setoid_rewrite <- Heqaddr in H1.
                       remember (addr_of_value vcom) as addr_set.
                       generalize dependent Cb. generalize dependent vcom.
                       induction H1.
                       - intros vcom Hload eq_addr_set Cb eq_addr; subst.
                         destruct vcom as [| [[[[]]]] |]; try by rewrite /= in_fset0 in H.
                         simpl in H. rewrite in_fset1 in H.
                         move: H => /eqP H; inversion H; subst; clear H.
                         eapply wfmem in wf_mem; last reflexivity.
                         destruct wf_mem as [wf_mem [_ _]].
                         specialize (wf_mem (Machine.R_COM) _ Logic.eq_refl) as
                           [v [v' [wf1 [wf2 wf3]]]].
                         rewrite <- C_next_e1 in wf1.
                         rewrite wf1 in Hload; inversion Hload; subst; clear Hload.
                         simpl in wf2. by [].
                       - intros vcom Hload eq_addr_set Cb eq_addr; subst.
                         apply In_in in H0; apply ComponentMemory.load_block_load in H0.
                         destruct H0 as [ptro [i compMem_bid_i]].
                         assert (Memory.load mem1 (Permission.data, cid, bid, i) =
                                   Some (Ptr (Permission.data, Cb, 0, ptro))) as Hload'.
                         { Local Transparent Memory.load.
                           unfold Memory.load; simpl; rewrite H compMem_bid_i.
                           reflexivity. }
                         eapply wfmem in wf_mem; last reflexivity.
                         destruct wf_mem as [wf_regs [post1 post2]].
                         specialize (IHReachable _ Hload Logic.eq_refl cid).
                         destruct bid; first contradiction.
                         rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem1) in Hload';
                           last (unfold Block.local; congruence).
                         rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem) in Hload';
                           last (unfold Block.local; congruence).
                         destruct (cid == C) eqn:eqC;
                           move: eqC => /eqP eqC; subst.
                         + specialize (post1 _ C_b C_next_e1).
                           destruct post1 as [_ [_ post1]].
                           apply steadysnap_shift in post1.
                           assert (not_local: S bid <> Block.local) by (unfold Block.local; congruence).
                           specialize (post1 (S bid) not_local).
                           destruct post1 as [[cid' bid'] [G1 [G2 G3]]].
                           specialize (G2 _ _ Hload') as [v' [_ renames]].
                           simpl in renames. discriminate.
                         + rewrite C_next_e1 in eqC.
                           assert (Cid_b: component_buffer cid).
                           { eapply load_in_intf in Hload'; eauto. }
                           specialize (post2 _ Cid_b eqC) as [post2 | post2].
                           * destruct post2 as [_ [_ post2]].
                             apply steadysnap_shift in post2.
                             assert (not_local: S bid <> Block.local) by (unfold Block.local; congruence).
                             specialize (post2 (S bid) not_local).
                             destruct post2 as [[cid' bid'] [G1 [G2 G3]]].
                             specialize (G2 _ _ Hload') as [v' [_ renames]].
                             simpl in renames. discriminate.
                           * destruct post2 as [_ [_ [[? ?] _]]].
                             destruct H2 as [src_compMem [mem0_cid nextblock]].
                             unfold Memory.load in Hload'.
                             rewrite /= mem0_cid in Hload'.
                             apply ComponentMemory.load_next_block in Hload'.
                             rewrite nextblock in Hload'.
                             unfold LOCALBUF_blockid in Hload'.
                             by []. }
                     { find_rcons_rcons. simpl in H2.
                       (*
  Hshift : traces_shift_each_other_option all_zeros_shift (uniform_shift 1)
             (project_non_inform (prefix0 ++ [:: e1])) (project_non_inform prefix_inform)
                        *)
                       inversion Hshift; subst.
                       clear -wf_mem Hmem Hmem1 wf_int_pref' H0 H H2 C_next_e1 C_b load_in_intf.
                       rename H2 into H1.
                       remember (Cb, 0) as addr. setoid_rewrite <- Heqaddr in H1.
                       remember (fset1 addr') as addr_set.
                       generalize dependent Cb. generalize dependent addr'.
                       induction H1.
                       - intros vcom shared eq_addr_set Cb eq_addr; subst.
                         destruct vcom as [].
                         simpl in H0. rewrite in_fset1 in H0.
                         move: H0 => /eqP H0; inversion H0; subst; clear H0.
                         setoid_rewrite cats1 in H.
                         inversion H.
                         + rewrite -H2 in shared; inversion shared.
                           * now destruct t.
                           * now destruct t.
                         + rewrite H0 in H3. rewrite H1 in H4.
                           apply H4 in shared.
                           destruct shared as [[? ?] [? [? ?]]].
                           clear -H10.
                           rewrite /all_zeros_shift /uniform_shift in H10.
                           rewrite /sigma_shifting_wrap_bid_in_addr /sigma_shifting_lefttoright_addr_bid in H10.
                           rewrite /sigma_shifting_lefttoright_option in H10.
                           destruct i1; simpl in H10;
                             rewrite ssrnat.subn0 ssrnat.addn1 in H10; congruence.
                       - intros vcom shared eq_addr_set Cb eq_addr; subst.
                         apply In_in in H2; apply ComponentMemory.load_block_load in H2.
                         destruct H2 as [ptro [i compMem_bid_i]].
                         assert (Memory.load mem1 (Permission.data, cid, bid, i) =
                                   Some (Ptr (Permission.data, Cb, 0, ptro))) as Hload'.
                         { Local Transparent Memory.load.
                           unfold Memory.load; simpl; rewrite H0 compMem_bid_i.
                           reflexivity.
                           Local Opaque Memory.load.
                         }
                         specialize (IHReachable _ shared Logic.eq_refl cid).
                         destruct bid; first contradiction.
                         rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem1) in Hload';
                           last (unfold Block.local; congruence).
                         rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem) in Hload';
                           last (unfold Block.local; congruence).
                         eapply wfmem in wf_mem; last reflexivity.
                         destruct wf_mem as [wf_regs [post1 post2]].
                         destruct (cid == C) eqn:eqC;
                           move: eqC => /eqP eqC; subst.
                         + specialize (post1 _ C_b C_next_e1).
                           destruct post1 as [_ [_ post1]].
                           apply steadysnap_shift in post1.
                           assert (not_local: S bid <> Block.local) by (unfold Block.local; congruence).
                           specialize (post1 (S bid) not_local).
                           destruct post1 as [[cid' bid'] [G1 [G2 G3]]].
                           specialize (G2 _ _ Hload') as [v' [_ renames]].
                           simpl in renames. discriminate.
                         + rewrite C_next_e1 in eqC.
                           assert (Cid_b: component_buffer cid).
                           { eapply load_in_intf in Hload'; eauto. }
                           specialize (post2 _ Cid_b eqC) as [post2 | post2].
                           * destruct post2 as [_ [_ post2]].
                             apply steadysnap_shift in post2.
                             assert (not_local: S bid <> Block.local) by (unfold Block.local; congruence).
                             specialize (post2 (S bid) not_local).
                             destruct post2 as [[cid' bid'] [G1 [G2 G3]]].
                             specialize (G2 _ _ Hload') as [v' [_ renames]].
                             simpl in renames. discriminate.
                           * destruct post2 as [_ [_ [[? ?] _]]].
                             destruct H3 as [src_compMem [mem0_cid nextblock]].
                             Local Transparent Memory.load.
                             unfold Memory.load in Hload'.
                             Local Opaque Memory.load.
                             rewrite /= mem0_cid in Hload'.
                             apply ComponentMemory.load_next_block in Hload'.
                             rewrite nextblock in Hload'.
                             unfold LOCALBUF_blockid in Hload'.
                             by []. }
                  ++
                    (* Use [addr_shared_so_far_inv_2] that is not yet stated *)
                    rename Hshared into Hshared'.
                    assert (Hshared: addr_shared_so_far (Cb, b)
                                                        (rcons (project_non_inform prefix) (ECall (cur_comp s) P' new_arg mem' C'))).
                    { inversion wf_cs' as [? ? ? ? ? ? ? ? ? ? ? ? ? ? wf_mem8 ?].
                      subst.
                      eapply wfmem in wf_mem8 as [wf_regs [wf_mem8 wf_mem8']];
                        last reflexivity.
                      eapply addr_shared_so_far_inv_2 with (mem := mem0); eauto.
                      -- intros. by simplify_memory'.
                      -- simpl.
                         unfold all_zeros_shift, uniform_shift.
                         destruct (wf_regs Machine.R_COM _ Logic.eq_refl) as [vcom' [newarg' [G1 [G2 G3]]]].
                         simpl in *.
                         assert (vcom' = vcom).
                         { rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem10) in G1; last congruence.
                           rewrite (Memory.load_after_store_eq _ _ _ _ Hmem9) in G1; congruence. } subst vcom'.
                         assert (newarg' = new_arg).
                         { apply ipref_evsteps in wf_int_pref'.
                           rewrite cats1 in wf_int_pref'.
                           inversion wf_int_pref'. now destruct prefix0.
                           destruct prefix0. simpl in *. congruence.
                           now destruct prefix0.
                           find_rcons_rcons. inversion H8; subst; eauto.
                         } subst.
                         auto.
                      -- eapply wfmem in wf_mem; last reflexivity.
                         destruct wf_mem as [_ [wf_mem _]].
                         intros; subst; simpl in *.
                         unfold postcondition_steady_state, postcondition_event_snapshot_steadystate in wf_mem.
                         specialize (wf_mem _ C_b C_next_e1) as [_ [_ [G _]]].
                         intros [| b'] not_local; first (unfold Block.local in not_local; congruence).
                         specialize (G _ not_local). destruct G as [addr [G1 [G2 G3]]].
                         eexists; split; last split; eauto.
                         ++ intros offset v Hload.
                            specialize (G2 _ _ Hload) as [v' [Hload' Hren]].
                            inversion wf_int_pref' as [U1 U2].
                            rewrite !cats1 in U1.
                            inversion U1.
                            ** now destruct prefix0.
                            ** now destruct prefix0 as [| ? []].
                            ** find_rcons_rcons. find_rcons_rcons.
                               inversion H9; subst; clear H9. eauto.
                         ++ intros offset v Hload.
                            inversion wf_int_pref' as [U1 U2].
                            rewrite !cats1 in U1.
                            inversion U1.
                            ** now destruct prefix0.
                            ** now destruct prefix0 as [| ? []].
                            ** find_rcons_rcons. find_rcons_rcons.
                               inversion H9; subst; clear H9. eauto.
                      -- eapply wfmem in wf_mem; last reflexivity.
                         destruct wf_mem as [_ [wf_mem1 wf_mem2]].
                         intros C0 C0_b.
                         destruct (C0 == next_comp_of_event e1) eqn:eC0;
                           move: eC0 => /eqP eC0; subst.
                         ++ left.
                            specialize (wf_mem1 _ C0_b Logic.eq_refl) as [_ [_ [G _]]].
                            { intros [| b'] not_local; first (unfold Block.local in not_local; congruence).
                              specialize (G _ not_local). destruct G as [addr [G1 [G2 G3]]].
                              eexists; split; last split; eauto.
                              ++ intros offset v Hload.
                                 specialize (G2 _ _ Hload) as [v' [Hload' Hren]].
                                 inversion wf_int_pref' as [U1 U2].
                                 rewrite !cats1 in U1.
                                 inversion U1.
                                 ** now destruct prefix0.
                                 ** now destruct prefix0 as [| ? []].
                                 ** find_rcons_rcons. find_rcons_rcons.
                                    inversion H8; subst; clear H8. eauto.
                              ++ intros offset v Hload.
                                 inversion wf_int_pref' as [U1 U2].
                                 rewrite !cats1 in U1.
                                 inversion U1.
                                 ** now destruct prefix0.
                                 ** now destruct prefix0 as [| ? []].
                                 ** find_rcons_rcons. find_rcons_rcons.
                                    inversion H8; subst; clear H8. eauto. }
                         ++ specialize (wf_mem2 C0 C0_b eC0) as [wf_mem2 | wf_mem2].
                            ** left. destruct wf_mem2 as [_ [_ [G _]]].
                               { intros [| b'] not_local; first (unfold Block.local in not_local; congruence).
                                 specialize (G _ not_local). destruct G as [addr [G1 [G2 G3]]].
                                 eexists; split; last split; eauto.
                                 ++ intros offset v Hload.
                                    specialize (G2 _ _ Hload) as [v' [Hload' Hren]].
                                    inversion wf_int_pref' as [U1 U2].
                                    rewrite !cats1 in U1.
                                    inversion U1.
                                    ** now destruct prefix0.
                                    ** now destruct prefix0 as [| ? []].
                                    ** find_rcons_rcons. find_rcons_rcons.
                                       inversion H8; subst; clear H8. eauto.
                                 ++ intros offset v Hload.
                                    inversion wf_int_pref' as [U1 U2].
                                    rewrite !cats1 in U1.
                                    inversion U1.
                                    ** now destruct prefix0.
                                    ** now destruct prefix0 as [| ? []].
                                    ** find_rcons_rcons. find_rcons_rcons.
                                       inversion H8; subst; clear H8. eauto. }
                            ** right.
                               destruct wf_mem2 as [_ [_ [_ G]]].
                               now rewrite cats1.
                      -- intros C0 b0 C0_b not_eq not_shared shared.
                         assert (inv_mem: CSInvariants.CSInvariants.wf_mem_wrt_t_pc
                                            (mem_of_event_inform e1)
                                            (project_non_inform (prefix0 ++ [:: e1]))
                                            C).
                         { destruct p_gens_t_inform as [x star].
                           rewrite Et in star.
                           eapply star_app_inv in star as [x0 [star1 _]];
                             last eapply CS.CS.singleton_traces_inform.
                           eapply CSInvariants.CSInvariants.wf_state_wf_mem; eauto.
                           eapply CSInvariants.CSInvariants.is_prefix_wf_state_t; eauto.
                           eapply CS.CS.star_sem_inform_star_sem_non_inform. eauto.
                           erewrite CS.CS.starR_memory_of_event_inform; first by reflexivity.
                           eapply star_iff_starR. rewrite cats1 in star1. simpl in star1. eauto.
                           erewrite <- CS.CS.starR_next_comp_of_event_inform. eauto.
                           eapply star_iff_starR. rewrite cats1 in star1. simpl in star1. eauto. }
                         assert (inv_regs: CSInvariants.CSInvariants.wf_reg_wrt_t_pc
                                             (register_file_of_event_inform e1)
                                             (project_non_inform (prefix0 ++ [:: e1]))
                                             C).
                         { destruct p_gens_t_inform as [x star].
                           rewrite Et in star.
                           eapply star_app_inv in star as [x0 [star1 _]];
                             last eapply CS.CS.singleton_traces_inform.
                           eapply CSInvariants.CSInvariants.wf_state_wf_reg; eauto.
                           eapply CSInvariants.CSInvariants.is_prefix_wf_state_t; eauto.
                           eapply CS.CS.star_sem_inform_star_sem_non_inform. eauto.
                           erewrite CS.CS.starR_register_file_of_event_inform; first by reflexivity.
                           eapply star_iff_starR. rewrite cats1 in star1. simpl in star1. eauto.
                           erewrite <- CS.CS.starR_next_comp_of_event_inform. eauto.
                           eapply star_iff_starR. rewrite cats1 in star1. simpl in star1. eauto. }
                         clear -inv_mem inv_regs shared not_shared not_eq wf_int_pref'.
                         inversion shared; subst; clear shared.
                         ++ find_rcons_rcons. simpl in H1.
                            remember (C0, b0) as addr.
                            rewrite -Heqaddr in H1.
                            remember (addr_of_value new_arg) as addr_set.
                            generalize dependent b0. generalize dependent C0. generalize dependent new_arg.
                            induction H1.
                            ** intros new_arg wf_int_pref' eq_addr_set C0 C0_cur b0 eq_addr; subst.
                               simpl in H. destruct new_arg as [| [[[[]]]] |]; try discriminate.
                               simpl in H. rewrite in_fset1 in H.
                               move: H => /eqP H. inversion H; subst; clear H.
                               unfold CSInvariants.CSInvariants.wf_reg_wrt_t_pc in inv_regs.
                               inversion wf_int_pref' as [U1 _].
                               rewrite !cats1 in U1.
                               inversion U1.
                               --- now destruct prefix0.
                               --- now destruct prefix0 as [| ? []].
                               --- find_rcons_rcons. find_rcons_rcons.
                                   inversion H1; subst; clear H1. simpl in *.
                                   specialize (inv_regs _ _ H11 Logic.eq_refl).
                                   inversion inv_regs; subst; clear inv_regs.
                                   +++ unfold C in C0_cur. contradiction.
                                   +++ contradiction.
                            ** intros new_arg wf_int_pref' eq_addr_set C0 C0_cur b0 eq_addr; subst.
                               apply In_in in H0.
                               apply ComponentMemory.load_block_load in H0 as [? [i Hload']].
                               assert (Hload: Memory.load mem' (Permission.data, cid, bid, i) =
                                                Some (Ptr (Permission.data, C0, b0, x))).
                               { Local Transparent Memory.load.
                                 unfold Memory.load. simpl. rewrite H. assumption.
                                 Local Opaque Memory.load. }
                               inversion wf_int_pref' as [U1 _].
                               rewrite !cats1 in U1.
                               inversion U1.
                               --- now destruct prefix0.
                               --- now destruct prefix0 as [| ? []].
                               --- find_rcons_rcons. find_rcons_rcons.
                                   inversion H3; subst; clear H3. simpl in *.
                                   specialize (inv_mem _ _ Hload Logic.eq_refl).
                                   inversion inv_mem; subst; clear inv_mem.
                                   (* CSInvariants.CSInvariants.wf_load *)
                                   +++ simpl in *. subst.
                                       specialize (IHReachable H3 _ wf_int_pref').
                                       eapply IHReachable; eauto.
                                   +++ simpl in *. subst. contradiction.
                                   +++ simpl in *. subst. contradiction.
                         ++ find_rcons_rcons. simpl in H2.
                            remember (C0, b0) as addr.
                            rewrite -Heqaddr in H2.
                            remember (fset1 addr') as addr_set.
                            generalize dependent b0. generalize dependent C0. generalize dependent addr'.
                            induction H2.
                            ** intros addr' shared eq_addr_set C0 C0_cur b0 eq_addr; subst.
                               simpl in H. destruct addr' as [cid bid].
                               simpl in H. rewrite in_fset1 in H.
                               move: H => /eqP H. inversion H; subst; clear H.
                               contradiction.
                            ** intros addr' shared eq_addr_set C0 C0_cur b0 eq_addr; subst.
                               apply In_in in H0.
                               apply ComponentMemory.load_block_load in H0 as [? [i Hload']].
                               assert (Hload: Memory.load mem' (Permission.data, cid, bid, i) =
                                                Some (Ptr (Permission.data, C0, b0, x))).
                               { Local Transparent Memory.load.
                                 unfold Memory.load. simpl. rewrite H. assumption.
                                 Local Opaque Memory.load. }
                               inversion wf_int_pref' as [U1 _].
                               rewrite !cats1 in U1.
                               inversion U1.
                               --- now destruct prefix0.
                               --- now destruct prefix0 as [| ? []].
                               --- find_rcons_rcons. find_rcons_rcons.
                                   inversion H3; subst; clear H3. simpl in *.
                                   specialize (inv_mem _ _ Hload Logic.eq_refl).
                                   inversion inv_mem; subst; clear inv_mem.
                                   (* CSInvariants.CSInvariants.wf_load *)
                                   +++ simpl in *. subst.
                                       eapply IHReachable; eauto.
                                   +++ simpl in *. subst. contradiction.
                                   +++ simpl in *. subst. contradiction.
                      -- intros C0 b0 o v Hload. unfold component_buffer.
                         (* Use p_interm and p_gens_t. *)
                         (* and (CS.CS.comes_from_initial_state_mem_domm _ intf). *)

                         (*replace intf with (Source.prog_interface ) by reflexivity.*)

                         pose proof (star_trans Star0 Star1 Logic.eq_refl) as G.
                         eapply CS.comes_from_initial_state_mem_domm in G; simpl in *; eauto.
                         ++ rewrite -G.
                            rewrite (Memory.domm_store _ _ _ _ Hmem1).
                            apply /dommP.
                            Local Transparent Memory.load.
                            unfold Memory.load in Hload. simpl in Hload.
                            destruct (mem1 C0) eqn:mem1_C0; last discriminate. by eauto.
                            Local Opaque Memory.load.
                         ++ {
                             eapply well_formed_events_well_formed_program
                             in wf_events as [theprog [Hrewr ?]]; eauto.
                             + erewrite Hprog_of_trace in Hrewr. inversion Hrewr.
                               by subst theprog.
                             + by eapply domm_t_procs_exported_procedures_of_trace.
                           }
                         ++ by apply closed_program_of_trace in Hprog_of_trace.
                         ++ by simpl.
                      -- intros ptr ? ? ?. simpl.
                         destruct (Pointer.eq ptr
                                              (Permission.data, C, Block.local, EXTCALL_offset)) eqn:eq_ptr;
                           move: eq_ptr => /Pointer.eqP eq_ptr; subst;
                                           [erewrite (Memory.load_after_store_eq _ _ _ _ Hmem1); eauto; by [] |
                                             erewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem1); eauto].
                         destruct (Pointer.eq ptr
                                              (Permission.data, C, Block.local, 0%Z)) eqn:eq_ptr';
                           move: eq_ptr' => /Pointer.eqP eq_ptr'; subst;
                                            [erewrite (Memory.load_after_store_eq _ _ _ _ Hmem); eauto; by [] |
                                              erewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem); eauto].
                         eapply wfmem_no_private_ptr; eauto.
                      -- eapply traces_rename_each_other_option_symmetric. reflexivity.
                         inversion Hshift; eauto.
                    } clear Hshared'.
                    exists (Cb, b). split; last split.
                    ** rewrite /all_zeros_shift /uniform_shift
                               /sigma_shifting_wrap_bid_in_addr
                               /sigma_shifting_lefttoright_addr_bid /=.
                       now rewrite ssrnat.subn0 ssrnat.addn1.
                    **
                      {
                        rewrite /all_zeros_shift /uniform_shift
                                /event_renames_event_at_shared_addr //=.
                        (* destruct cs'.simpl in mem_cs'; subst s_memory. *)
                        (* MARK 2 *)
                        inversion wf_cs' as [? ? ? ? ? ? ? ? ? ? ? ? ? ? wf_mem10 ?].
                        subst C0 stk0 mem11 arg0 k exp.
                        eapply wfmem in wf_mem10 as [wf_regs [wf_mem10 wf_mem10']];
                          last reflexivity.
                        simpl in wf_regs, wf_mem10, wf_mem10'.
                        unfold postcondition_steady_state in wf_mem10.
                        unfold postcondition_event_snapshot_steadystate in wf_mem10.
                        case Cb_C: (Cb == C'); move: Cb_C => /eqP Cb_C; [subst Cb |].
                        * specialize (wf_mem10 _ C'_b Logic.eq_refl) as [_ [_ [Hshift1 _]]].
                          unfold well_formed_memory_snapshot_steadystate_shift in Hshift1.
                          unfold memory_shifts_memory_at_shared_addr in Hshift1.
                          unfold all_zeros_shift, uniform_shift in Hshift1.
                          simpl in Hshift1.
                          specialize (Hshift1 (S b)).
                          unfold memory_renames_memory_at_shared_addr in *.
                          eexists (C', S b).
                          split; [| split].
                          -- rewrite /sigma_shifting_wrap_bid_in_addr. simpl.
                             by rewrite ssrnat.subn0 ssrnat.addn1.
                          -- intros off v Hload; simpl in *.
                             destruct Hshift1 as [addr' [Hshift1 [Hshift2 Hshift3]]];
                               first easy.
                             rewrite /sigma_shifting_wrap_bid_in_addr //= in Hshift1.
                             rewrite ssrnat.subn1 ssrnat.addn0 in Hshift1.
                             inversion Hshift1; subst addr'.
                             simpl in Hshift3.
                             specialize (Hshift3 _ _ Hload) as [? [? ?]].
                             destruct steady_C3'' as [Hsteady | Huninit].
                             {
                               eexists; split.
                               ++ repeat match goal with
                                         | Hload: Memory.load ?mem' ?ptr' = Some ?v',
                                             Hstore: Memory.store ?mem ?ptr ?v = Some ?mem' |- _ =>
                                             erewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hstore) in Hload
                                         end.

                                  rewrite Hsteady_localbuf2; eauto.
                               ++ destruct x; simpl in *; try by inversion H7; subst v.
                                  destruct t0 as [[[[|] ?] ?] ?]; simpl in *.
                                  by inversion H7.
                                  destruct i0; inversion H7; subst v.
                                  by rewrite //= ssrnat.subn1 ssrnat.addn0 ssrnat.subn0 ssrnat.addn1.
                             }
                             {
                               destruct p_gens_t as [? G].
                               rewrite Et project_non_inform_append in G.
                               simpl in G. unfold Eapp in G.
                               replace ((ECall (cur_comp s) P' new_arg mem' C' :: project_non_inform suffix)) with ([:: ECall (cur_comp s) P' new_arg mem' C'] ++ project_non_inform suffix) in G; last reflexivity.
                               setoid_rewrite app_assoc in G.
                               apply star_app_inv in G as [? [G _]].
                               setoid_rewrite cats1 in G.

                               eapply CSInvariants.CSInvariants.not_executing_can_not_share in
                                 Hshared; eauto; first contradiction.
                               + move : C_ne_C' => /eqP => ?. by auto.
                               + rewrite Hprefix01 cats1. by destruct Huninit as [? [? [? ?]]].
                               + apply CS.CS.singleton_traces_non_inform.
                             }
                          -- intros off v Hload; simpl in *.
                             destruct Hshift1 as [addr' [Hshift1 [Hshift2 Hshift3]]];
                               first easy.
                             rewrite /sigma_shifting_wrap_bid_in_addr //= in Hshift1.
                             rewrite ssrnat.subn1 ssrnat.addn0 in Hshift1.
                             inversion Hshift1; subst addr'.
                             simpl in Hshift2.
                             (* *)
                             destruct steady_C3'' as [Hsteady | Huninit].
                             {
                               repeat match goal with
                                      | Hload: Memory.load ?mem' ?ptr' = Some ?v',
                                          Hstore: Memory.store ?mem ?ptr ?v = Some ?mem' |- _ =>
                                          erewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hstore) in Hload
                                      end.
                               assert (Hload': Memory.load mem10 (Permission.data, C', S b, off) = Some v).
                               { simplify_memory.
                                 rewrite -Hsteady_localbuf2; eauto.
                                 simplify_memory.
                               }
                               specialize (Hshift2 _ _ Hload') as [v' [G Hv']].

                               eexists; split; first eassumption.
                               destruct v; simpl in *; try by inversion Hv'; subst.
                               destruct t0 as [[[[|] ?] ?] ?]; simpl in *; first by inversion Hv'.
                               destruct i0; inversion Hv'; subst.
                               by rewrite //= ssrnat.subn1 ssrnat.addn0 ssrnat.subn0 ssrnat.addn1.
                             }
                             {
                               destruct p_gens_t as [? G].
                               rewrite Et project_non_inform_append in G.
                               simpl in G. unfold Eapp in G.
                               replace ((ECall (cur_comp s) P' new_arg mem' C' :: project_non_inform suffix)) with ([:: ECall (cur_comp s) P' new_arg mem' C'] ++ project_non_inform suffix) in G; last reflexivity.
                               setoid_rewrite app_assoc in G.
                               apply star_app_inv in G as [? [G _]].
                               setoid_rewrite cats1 in G.

                               eapply CSInvariants.CSInvariants.not_executing_can_not_share in
                                 Hshared; eauto; first contradiction.
                               + move : C_ne_C' => /eqP => ?. by auto.
                               + rewrite Hprefix01 cats1. by destruct Huninit as [? [? [? ?]]].
                               + apply CS.CS.singleton_traces_non_inform.
                             }

                        * (* Prove good_trace something. Get from Hshared that there's a
                           * load and [1 <= b]. Now we can get a contradiction to
                           * [postcondition_uninitialized] *)
                          (* *)
                          exists (Cb, S b).
                          split.
                          -- rewrite /all_zeros_shift /uniform_shift //=.
                             rewrite /sigma_shifting_wrap_bid_in_addr //=.
                             by rewrite ssrnat.subn0 ssrnat.addn1.
                          -- assert (Hwf_p: Source.well_formed_program p).
                             {
                               eapply well_formed_events_well_formed_program
                                 in wf_events as [p_wf [Hp_wf1 Hp_wf2]]; eauto.
                               + erewrite Hprog_of_trace in Hp_wf1. inversion Hp_wf1.
                                 by subst p_wf.
                               + by eapply domm_t_procs_exported_procedures_of_trace.
                             }
                             assert (Hclosed_p: Source.closed_program p).
                             {
                               by eapply closed_program_of_trace; eauto.
                             }
                             split; intros ? ? Hload.
                             ++ simpl in *.
                                assert (HCb: component_buffer Cb).
                                {
                                  (** This essentially follows IF we knew that the
                          intermediate trace came from an intermediate execution.
                          Then, we can possibly use a lemma in CSInvariants? *)

                                  unfold component_buffer.
                                  replace intf with (Machine.Intermediate.prog_interface p_interm).
                                  destruct p_gens_t as [? G].
                                  rewrite Et project_non_inform_append in G.
                                  simpl in G. unfold Eapp in G.
                                  replace ((ECall (cur_comp s) P' new_arg mem' C' :: project_non_inform suffix)) with ([:: ECall (cur_comp s) P' new_arg mem' C'] ++ project_non_inform suffix) in G; last reflexivity.
                                  setoid_rewrite app_assoc in G.
                                  apply star_app_inv in G as [? [G _]].
                                  setoid_rewrite cats1 in G.
                                  eapply CSInvariants.CSInvariants.load_Some_component_buffer with
                                    (ptr := (Permission.data, Cb, b, offset))
                                    (e := (ECall (cur_comp s) P' new_arg mem' C')); eauto.
                                  apply CS.CS.singleton_traces_non_inform.
                                }
                                specialize (wf_mem10' _ HCb Cb_C) as
                                  [[? [? [? ?]]] | [? [? [[[compMem [? HcompMem]] ?] Hnot_shared]]] ].
                                ** assert (Hnoteq: S b <> Block.local).
                                   { by unfold Block.local. }
                                   specialize (steadysnap_shift0 _ Hnoteq)
                                     as [[C_ b_] [Hb_ [mem10_mem' mem'_mem10]]].
                                   rewrite shift_S_Some in Hb_.
                                   inversion Hb_; subst C_ b_; clear Hb_.
                                   simpl in *.
                                   specialize (mem'_mem10 _ _ Hload) as [v' [Hloadv' Hv']].
                                   exists v'. split.
                                   --- simplify_memory_in_assm. rewrite Hmem2'; eauto.
                                   --- specialize (shift_value_option_symmetry
                                                     (fun=> 1) (fun=> 0)) as Lem.
                                       unfold shift_value_option,
                                         sigma_shifting_wrap_bid_in_addr,
                                         sigma_shifting_lefttoright_addr_bid,
                                         rename_addr_option in *.
                                       by eapply Lem.
                                ** simpl in *. destruct HcompMem as [HcompMem [? [Hnext ?]]].
                                   (** Intuitively, there should be a contradiction. *)
                                   (** In particular, ** is the case where Cb is not *)
                                   (** initialized. What we know about Cb is that it *)
                                   (** shared an address and that this address also was *)
                                   (** loaded from memory (Hload). *)
                                   specialize (Hnot_shared b).
                                   rewrite -!cats1 project_non_inform_append /= in Hnot_shared.
                                   setoid_rewrite cats1 in Hnot_shared.
                                   apply Hnot_shared in Hshared.
                                   contradiction.
                             ++ simpl in *.
                                assert (Hload': Memory.load
                                                  mem10
                                                  (Permission.data, Cb, S b, offset) = Some v').
                                { simplify_memory. rewrite -Hmem2'. eauto. eauto. }
                                (** Need to know component_buffer Cb. *)
                                (** Intuitively, we should know it from Hload *)
                                (** Knowing it from Hload should be a source "CSInvariant". *)

                                assert (HCb: component_buffer Cb).
                                {
                                  unfold component_buffer.
                                  replace intf with (Machine.Intermediate.prog_interface p_interm).

                                  assert (starG : star CS.kstep (prepare_global_env p) (CS.initial_machine_state p)
                                                       (rcons (project_non_inform prefix_inform) (ECall (cur_comp s) P' vcom mem1 C'))

                                                       [CState C', {|
                                                                     CS.f_component := C;
                                                                     CS.f_arg := arg;
                                                                     CS.f_cont := Kassign1 (loc_of_reg E_R_COM)
                                                                                           (Kseq
                                                                                              (invalidate_metadata;;
                                                                                               E_assign EXTCALL (E_val (Int 0));;
                                                                                               E_call C P (E_val (Int 0))) Kstop) |} :: stk, mem10, Kstop,
                                                         expr_of_trace C' P' (comp_subtrace C' t), vcom]
                                         ).
                                  {
                                    rewrite -cats1.
                                    eapply star_trans; eauto.
                                    - eapply star_trans; eauto.
                                    - simpl. subst. by unfold C.
                                  }
                                  specialize (@CS.CS.load_component_prog_interface_addr
                                                _ Hwf_p Hclosed_p _ _ _
                                                (Permission.data, Cb, S b, offset) v'
                                                Logic.eq_refl starG
                                             ) as G'.
                                  simpl in *. rewrite p_interm_intf.
                                  by subst p; intuition.
                                }

                                specialize (wf_mem10' _ HCb Cb_C) as
                                  [[? [? [? ?]]] | [? [? [[[compMem [? HcompMem]] ?] Hnot_shared]]] ].
                                ** assert (Hnoteq: S b <> Block.local).
                                   { by unfold Block.local. }
                                   specialize (steadysnap_shift0 _ Hnoteq)
                                     as [[C_ b_] [Hb_ [mem10_mem' mem'_mem10]]].
                                   rewrite shift_S_Some in Hb_.
                                   inversion Hb_; subst C_ b_; clear Hb_.
                                   simpl in *.
                                   specialize (mem10_mem' _ _ Hload') as [v'' [Hloadv' Hv']].
                                   exists v''. split.
                                   --- assumption.
                                   --- specialize (shift_value_option_symmetry
                                                     (fun=> 1) (fun=> 0)) as Lem.
                                       unfold shift_value_option,
                                         sigma_shifting_wrap_bid_in_addr,
                                         sigma_shifting_lefttoright_addr_bid,
                                         rename_addr_option in *.
                                       by eapply Lem.
                                ** simpl in HcompMem.
                                   destruct H8 as [src_compMem [Hsrc_compMem Hnextblock]].
                                   assert (Memory.next_block mem10 Cb = Some LOCALBUF_blockid).
                                   unfold Memory.next_block; rewrite Hsrc_compMem Hnextblock //=.
                                   replace Cb with
                                     (Pointer.component (Permission.data, Cb, S b, offset)) in H8 by reflexivity.
                                   apply Memory.load_next_block_None in H8. congruence.
                                   simpl. unfold LOCALBUF_blockid. apply /ssrnat.leP. lia.


                      }
                    ** eauto.
                - easy.
                - rewrite /all_zeros_shift /uniform_shift
                          /sigma_shifting_wrap_bid_in_addr
                          /sigma_shifting_lefttoright_addr_bid /=.
                  destruct new_arg.
                  + rewrite //=.
                    destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                    inversion wf_int_pref'.
                    * now destruct prefix.
                    * destruct prefix as [|? []]; try discriminate.
                      now destruct prefix0.
                    * rewrite cats1 in H. apply rcons_inj in H. inversion H; subst; clear H.
                      rewrite cats1 in H3. apply rcons_inj in H3. inversion H3; subst; clear H3.
                      inversion H1; subst; clear H1. simpl in *.
                      pose proof (wfmem wf_mem Logic.eq_refl) as [Hregs [Hnextcomp Hnotnextcomp]].
                      specialize (Hregs Machine.R_COM _ Logic.eq_refl) as [v [v' [H1 H2]]].
                      simpl in *.
                      rewrite -C_next_e1 in H1.
                      rewrite H1 in Hvcom. inversion Hvcom. subst. destruct H2 as [H2 H3].
                      rewrite H3 in H11; subst. rewrite H11 in H2.
                      destruct vcom; try discriminate. simpl in H2. eauto. simpl in H2.
                      destruct t0 as [[[]]]. destruct (Permission.eqb i Permission.data);
                                               try discriminate.
                      rewrite /all_zeros_shift /uniform_shift in H2.
                      rewrite /rename_addr_option //= in H2.
                      rewrite /sigma_shifting_wrap_bid_in_addr
                              /sigma_shifting_lefttoright_addr_bid
                              /sigma_shifting_lefttoright_option in H2.
                      destruct i1; simpl in H2. discriminate.
                      inversion H2.
                  + destruct t0 as [[[? ?] ?] ?].
                    destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                    inversion wf_int_pref'.
                    * now destruct prefix.
                    * destruct prefix as [|? []]; try discriminate.
                      now destruct prefix0.
                    * rewrite cats1 in H. apply rcons_inj in H. inversion H; subst; clear H.
                      rewrite cats1 in H3. apply rcons_inj in H3. inversion H3; subst; clear H3.
                      inversion H1; subst; clear H1. simpl in *.
                      pose proof (wfmem wf_mem Logic.eq_refl) as [Hregs [Hnextcomp Hnotnextcomp]].
                      specialize (Hregs Machine.R_COM _ Logic.eq_refl) as [v [v' [H1 H2]]].
                      simpl in *.
                      rewrite -C_next_e1 in H1.
                      rewrite H1 in Hvcom. inversion Hvcom. subst; clear Hvcom.
                      destruct H2 as [H2 H3].
                      rewrite H3 in H11; subst. rewrite H11 in H2.
                      destruct vcom; try discriminate. simpl in H2.
                      destruct t0 as [[[]]].
                      (* destruct (Permission.eqb i2 Permission.data); *)
                      (*   try discriminate. *)
                      rewrite /all_zeros_shift /uniform_shift in H2.
                      rewrite /rename_addr_option //= in H2.
                      rewrite /sigma_shifting_wrap_bid_in_addr
                              /sigma_shifting_lefttoright_addr_bid
                              /sigma_shifting_lefttoright_option in H2.
                      destruct (Permission.eqb i2 Permission.data) eqn:perm1;
                        destruct (Permission.eqb i Permission.data) eqn:perm2; simpl in *.
                      -- destruct i4; simpl in H2; try discriminate.
                         inversion H2; subst; clear H2.
                         rewrite ssrnat.subn1 //= ssrnat.addn0 ssrnat.subn0 ssrnat.addn1 //=.
                      -- destruct i4; simpl in H2; try discriminate.
                         inversion H2; subst; clear H2. congruence.
                      -- destruct i4; simpl in H2; try discriminate;
                           inversion H2; subst; clear H2; congruence.
                      -- destruct i4; simpl in H2; try discriminate;
                           inversion H2; subst; clear H2; reflexivity.
                  + rewrite //=.
                    destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                    inversion wf_int_pref'.
                    * now destruct prefix.
                    * destruct prefix as [|? []]; try discriminate.
                      now destruct prefix0.
                    * rewrite cats1 in H. apply rcons_inj in H. inversion H; subst; clear H.
                      rewrite cats1 in H3. apply rcons_inj in H3. inversion H3; subst; clear H3.
                      inversion H1; subst; clear H1. simpl in *.
                      pose proof (wfmem wf_mem Logic.eq_refl) as [Hregs [Hnextcomp Hnotnextcomp]].
                      specialize (Hregs Machine.R_COM _ Logic.eq_refl) as [v [v' [H1 H2]]].
                      simpl in *.
                      rewrite -C_next_e1 in H1.
                      rewrite H1 in Hvcom. inversion Hvcom. subst. destruct H2 as [H2 H3].
                      rewrite H3 in H11; subst. rewrite H11 in H2.
                      destruct vcom; try discriminate. simpl in H2. eauto. simpl in H2.
                      destruct t0 as [[[]]]. destruct (Permission.eqb i Permission.data);
                                               try discriminate.
                      rewrite /all_zeros_shift /uniform_shift in H2.
                      rewrite /rename_addr_option //= in H2.
                      rewrite /sigma_shifting_wrap_bid_in_addr
                              /sigma_shifting_lefttoright_addr_bid
                              /sigma_shifting_lefttoright_option in H2.
                      destruct i1; simpl in H2. discriminate.
                      inversion H2. auto.
                - constructor.
                  intros [Cb b] Hshared.
                  constructor.
                - constructor.
                  intros [Cb b] Hshared.
                  (* rewrite /right_addr_good_for_shifting. *)
                  (* rewrite /right_block_id_good_for_shifting /uniform_shift. *)
                  inversion Hshared; subst; clear Hshared.
                  + find_rcons_rcons. simpl in *.
                    remember (Cb, b) as addr. generalize dependent b. generalize dependent Cb.
                    inversion H1; intros; subst.
                    * destruct vcom as [| [[[[]]]] |]; try by rewrite in_fset0 in H.
                      rewrite in_fset1 in H. move: H => /eqP H; inversion H; subst.
                      specialize (steady_C1 Machine.R_COM _ Logic.eq_refl) as [vcom1 [vcom2 [G1 [G2 _]]]].
                      simpl in G1. unfold C in C_next_e1; rewrite C_next_e1 in Hvcom. rewrite G1 in Hvcom.
                      inversion Hvcom; subst.
                      rewrite /all_zeros_shift /uniform_shift //= in G2.
                      destruct i0; try discriminate. constructor.
                    * apply In_in in H2. apply ComponentMemory.load_block_load in H2 as [off' [off Hload]].
                      assert (load: Memory.load mem1 (Permission.data, cid, bid, off) =
                                      Some (Ptr (Permission.data, Cb, b, off'))).
                      { Local Transparent Memory.load.
                        unfold Memory.load. simpl.
                        rewrite H0. assumption.
                        Local Opaque Memory.load.
                      }
                      rewrite (Memory.load_after_store _ _ _ _ _ Hmem1) in load.
                      move: load; case: ifP => //= _ load.
                      rewrite (Memory.load_after_store _ _ _ _ _ Hmem) in load.
                      move: load; case: ifP => //= _ load.
                      eapply wfmem_no_private_ptr in load; eauto.
                      now destruct b.
                  + find_rcons_rcons.
                    inversion H2; intros; subst.
                    * inversion Hshift; subst; clear Hshift.
                      inversion H1; subst; clear H1. rewrite <- H5 in H0; inversion H0; try now destruct t0.
                      rewrite H4 in H12.
                      inversion H12; subst; clear H12.
                      eapply H1 in H0. by rewrite in_fset1 in H; move: H => /eqP ->.
                    * apply In_in in H3. apply ComponentMemory.load_block_load in H3 as [off' [off Hload]].
                      assert (load: Memory.load mem1 (Permission.data, cid, bid, off) =
                                      Some (Ptr (Permission.data, Cb, b, off'))).
                      { Local Transparent Memory.load.
                        unfold Memory.load. simpl.
                        rewrite H1. assumption.
                        Local Opaque Memory.load.
                      }
                      rewrite (Memory.load_after_store _ _ _ _ _ Hmem1) in load.
                      move: load; case: ifP => //= _ load.
                      rewrite (Memory.load_after_store _ _ _ _ _ Hmem) in load.
                      move: load; case: ifP => //= _ load.
                      eapply wfmem_no_private_ptr in load; eauto.
                      now destruct b.
              }
          (* END CASE: CALL *)

          (* CASE: [ERet], [ERetInform] *)
          - assert (prefix = [::] \/ exists prefix' e', prefix = prefix' ++ [:: e'])
            as [Hprefix | [prefix0 [e1 Hprefix01]]].
            {
              destruct prefix; first by auto.
              right. rewrite lastI -cats1. by eauto.
            }
            { (* This should result in a contradiction: the first event cannot be a return *)
              exfalso.
              subst.
              move: wb_trace.
              by move => /andP [].
            }

            (* destruct (wfmem_call wf_mem (Logic.eq_refl _) C_b) as [Hmem Harg]. *)
            simpl.
            pose proof (wfmem_extcall wf_mem Hprefix01) as [Hextcall_C Hextcall_notC].
            (* have C'_b := valid_procedure_has_block (or_intror (closed_intf Himport)). *)
            assert (C_next_e1: C = next_comp_of_event e1).
            { destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
              rewrite Hprefix01 in wf_ev_comps'.
              setoid_rewrite <- app_assoc in wf_ev_comps'.
              apply trace_event_components_app_r in wf_ev_comps'.
              setoid_rewrite cats1 in wf_ev_comps'.
              inversion wf_ev_comps'. rewrite lastI in H.
              apply rcons_inj in H. inversion H. subst e2. clear H.
              rewrite -cats1 in H3. apply elt_eq_unit in H3 as [? [? _]]. subst e0 t0.
              by rewrite H0.
            }

            specialize (Hextcall_C C C_b C_next_e1).
            assert (C'_next_e1: C' <> next_comp_of_event e1)
              by (rewrite -C_next_e1 /C; move: wf_e => /eqP; congruence).
            assert (C'_b: component_buffer C').
            {
              destruct s.
              destruct callers as [|C'_ callers]; try easy.
              case/andP: wb=> [/eqP HC' wb_suffix].
              subst C'_.
              destruct wf_stk as (top & bot & ? & Htop & Hbot). subst stk. simpl in Htop, Hbot.
              destruct Hbot as [Hbot_load Hbot].
              destruct Hbot as (saved & P' & top' & bot' & ? & P'_exp & Htop' & Hbot').
              eapply valid_procedure_has_block; eassumption.
            }
            have HextcallC' := Hextcall_notC C' C'_b C'_next_e1.


            (* Memory operations and initialization check *)
            destruct (Memory.store_after_load mem (Permission.data, C, Block.local, EXTCALL_offset)
                                              (Int 0) (Int 1)) as [mem1 Hmem1]; simplify_memory.
            destruct (wfmem_meta wf_mem E_R_COM C_b) as [vcom Hcom].

            assert (Star_deref: star CS.kstep (prepare_global_env p)
                                     [CState C, stk, mem, Kstop, E_assign EXTCALL (E_val (Int 1));;
                                                                 E_deref (loc_of_reg E_R_COM), arg]
                                     [::]
                                     [CState C, stk, mem1, Kstop, E_val vcom, arg]).
            { take_steps. eauto.
              Local Transparent loc_of_reg.
              take_steps. simplify_memory.
              apply star_refl. }


            pose proof (wfmem_meta wf_mem E_R_ONE C'_b) as [v1 Hv1].
            pose proof (wfmem_meta wf_mem E_R_AUX1 C'_b) as [v2 Hv2].
            pose proof (wfmem_meta wf_mem E_R_AUX2 C'_b) as [v3 Hv3].
            pose proof (wfmem_meta wf_mem E_R_RA C'_b) as [v4 Hv4].
            pose proof (wfmem_meta wf_mem E_R_SP C'_b) as [v5 Hv5].
            pose proof (wfmem_meta wf_mem E_R_ARG C'_b) as [v6 Hv6].
            pose proof (wfmem_meta wf_mem E_R_COM C'_b) as [v7 Hv7].
            destruct (Memory.store_after_load mem1
                                              (Permission.data, C', Block.local, reg_offset E_R_COM)
                                              v7 vcom) as [mem1' Hmem1']; simplify_memory.
            destruct (Memory.store_after_load mem1'
                                              (Permission.data, C', Block.local, reg_offset E_R_ONE)
                                              v1 Undef) as [mem2 Hmem2]; simplify_memory.
            destruct (Memory.store_after_load mem2
                                              (Permission.data, C', Block.local, reg_offset E_R_AUX1)
                                              v2 Undef) as [mem3 Hmem3]; simplify_memory.
            destruct (Memory.store_after_load mem3
                                              (Permission.data, C', Block.local, reg_offset E_R_AUX2)
                                              v3 Undef) as [mem4 Hmem4]; simplify_memory.
            destruct (Memory.store_after_load mem4
                                              (Permission.data, C', Block.local, reg_offset E_R_RA)
                                              v4 Undef) as [mem5 Hmem5]; simplify_memory.
            destruct (Memory.store_after_load mem5
                                              (Permission.data, C', Block.local, reg_offset E_R_SP)
                                              v5 Undef) as [mem6 Hmem6]; simplify_memory.
            destruct (Memory.store_after_load mem6
                                              (Permission.data, C', Block.local, reg_offset E_R_ARG)
                                              v6 Undef) as [mem7 Hmem7]; simplify_memory.

            destruct (Memory.store_after_load mem7
                                              (Permission.data, C', Block.local, EXTCALL_offset)
                                              (Int 1) (Int 0)) as [mem8 Hmem8]; simplify_memory.

            assert (Star_ret: exists s' cs',
                       star CS.kstep (prepare_global_env p)
                            [CState C, stk, mem1, Kstop, E_val vcom, arg]
                            [:: ERet C vcom mem1 C']
                            cs' /\
                         CS.s_memory cs' = mem8 /\
                         well_formed_state_r
                           s'
                           (prefix ++ [:: ERetInform (cur_comp s) ret_val mem' regs C']) suffix
                           cs').
            { clear Star_deref Star0.
              destruct s.
              destruct callers as [|C'_ callers]; try easy.
              case/andP: wb=> [/eqP HC' wb_suffix].
              subst C'_. exists (StackState C' callers).
              destruct wf_stk as (top & bot & ? & Htop & Hbot). subst stk. simpl in Htop, Hbot.
              destruct Hbot as [Hbot_load Hbot].
              (* clear Hmem Hmem1. *)
              (* clear Hmem1. *)
              clear Star1.
              revert mem1 Hmem1' Hmem1 Hmem2 arg.
              induction top as [|[C_ saved k_] top IHtop].
              - clear Htop. rename bot into bot'.

                destruct Hbot as (saved & P' & top & bot & ? & P'_exp & Htop & Hbot).
                subst bot'. simpl.
                (* have C'_b := valid_procedure_has_block P'_exp. *)
                intros mem1 Hmem1' Hmem1 Hmem2 arg.
                eexists. split; last split.
                + simpl.
                  eapply star_step.
                  * eapply CS.KS_ExternalReturn; congruence.
                  * take_steps; eauto.
                    take_steps; eauto.
                    take_steps; eauto.
                    take_steps; eauto.
                    take_steps; eauto.
                    take_steps; eauto.
                    take_steps; eauto.
                    take_steps; eauto.
                    take_steps. simpl. erewrite find_procedures_of_trace; eauto; by subst p.
                    take_steps. simplify_memory.
                    take_steps; simplify_memory.
                    take_steps.
                    eapply star_refl.
                  * now rewrite E0_right.
                + by simpl.
                + econstructor; trivial.
                  exact wf_suffix.
                  exists (CS.Frame C' saved Kstop :: top), bot; simpl; auto.
                  split. reflexivity. split. split. eauto. eauto.
                  subst C.
                  {
                    elim: callers Hmem Hmem1 bot Hbot
                                  {Et wf_int_pref' wf_e Hextcall_C C_next_e1 wf_C C_b P_exp Hcom wb_suffix}.
                    * by [].
                    * move=> a l IH Hmem Hmem1 bot [] H1 H2.
                      fold well_formed_callers in *.
                      split.
                      -- simplify_memory.
                      -- destruct H2 as [? [? [? [? [? [? [? H2]]]]]]].
                         eexists; eexists; eexists; eexists; eauto.
                  }
                  {
                    subst C. simpl in *. rename cur_comp into C.
                    constructor.
                    - (* [wfmem_counter] *)
                      move=> C0 C0_b.
                      rewrite counter_value_snoc.
                      case: ifP => //= /eqP C_C0; [subst C0 |]; simplify_memory=> //=.
                      + by rewrite counter_value_snoc eqxx.
                      + rewrite Z.add_0_r.
                        by apply wfmem_counter.
                    - (* [wfmem_extcall_ini] *)
                      by case prefix.
                    - (* [wfmem_extcall] *)
                      move=> prefix'0 e'0.
                      rewrite 2!cats1 => /rcons_inj [] ? ?; subst prefix'0 e'0.
                      split.
                      + move=> C0 C0_b //= ->.
                        simplify_memory.
                      + move=> C0 C0_b //= C0_C'.
                        case C0_C: (C0 == C);
                          move: C0_C => /eqP C0_C; [subst C0|]; simplify_memory.
                        by eapply Hextcall_notC; congruence.
                    - (* [wfmem_meta] *)
                      move=> C0 r C0_b.
                      case C0_C: (C0 == C);
                        move: C0_C => /eqP C0_C; [subst C0|
                                                   case C0_C': (C0 == C');
                                                   move: C0_C' => /eqP C0_C'; [subst C0|]].
                      + edestruct wfmem_meta with (r := r) as [v Hv]; eauto.
                        exists v. by simplify_memory'.
                      + edestruct (wfmem_meta) with (r := E_R_COM) as [vcomC' HcomC']; eauto.
                        by destruct r; eexists; simplify_memory'; eauto.
                      + edestruct wfmem_meta with (r := r) as [v Hv]; eauto.
                        exists v. by simplify_memory'.
                    - (* [wfmem_ini] *)
                      by case prefix.
                    - (* [wfmem] *)
                      move=> prefix'0 e'0.
                      rewrite 2!cats1 => /rcons_inj [] ? ?; subst prefix'0 e'0.
                      split; last split.
                      + {
                        intros reg off Hoffset.
                        pose proof (wfmem wf_mem Hprefix01) as [Hregs [Hnextcomp Hnotnextcomp]].
                        subst off.
                        destruct reg; eexists; eexists; (split; [| split]);
                          try by simplify_memory';
                          try by reflexivity.
                        - destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                          inversion wf_int_pref'.
                          + now destruct prefix.
                          + destruct prefix as [|? []]; try discriminate.
                            inversion H; subst e; clear H.
                            inversion H0; subst; clear H0.
                            now auto.
                          + rewrite cats1 in H. apply rcons_inj in H. inversion H; subst; clear H.
                            inversion H1; subst; clear H1. auto.
                        - (* RCOM! *)
                          specialize (Hregs Machine.R_COM _ Logic.eq_refl) as [v [v' [Hload [Hshift' Hblock']]]].
                          simpl in Hload.
                          rewrite -C_next_e1 Hcom in Hload. inversion Hload; subst; clear Hload.
                          rewrite Hshift'. simpl.
                          destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                          inversion wf_int_pref'; subst.
                          + now destruct prefix0.
                          + destruct prefix0 as [|? []]; try discriminate.
                          + rewrite cats1 in H. apply rcons_inj in H. inversion H; subst; clear H.
                            rewrite cats1 in H3. apply rcons_inj in H3. inversion H3; subst; clear H3.
                            inversion H1; subst; clear H1. auto.
                        - destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                          inversion wf_int_pref'.
                          + now destruct prefix.
                          + destruct prefix as [|? []]; try discriminate.
                            inversion H; subst e; clear H.
                            inversion H0; subst; clear H0.
                            now auto.
                          + rewrite cats1 in H. apply rcons_inj in H. inversion H; subst; clear H.
                            inversion H1; subst; clear H1. auto.
                        - destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                          inversion wf_int_pref'.
                          + now destruct prefix.
                          + destruct prefix as [|? []]; try discriminate.
                            inversion H; subst e; clear H.
                            inversion H0; subst; clear H0.
                            now auto.
                          + rewrite cats1 in H. apply rcons_inj in H. inversion H; subst; clear H.
                            inversion H1; subst; clear H1. auto.
                        - destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                          inversion wf_int_pref'.
                          + now destruct prefix.
                          + destruct prefix as [|? []]; try discriminate.
                            inversion H; subst e; clear H.
                            inversion H0; subst; clear H0.
                            now auto.
                          + rewrite cats1 in H. apply rcons_inj in H. inversion H; subst; clear H.
                            inversion H1; subst; clear H1. auto.
                        - destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                          inversion wf_int_pref'.
                          + now destruct prefix.
                          + destruct prefix as [|? []]; try discriminate.
                            inversion H; subst e; clear H.
                            inversion H0; subst; clear H0.
                            now auto.
                          + rewrite cats1 in H. apply rcons_inj in H. inversion H; subst; clear H.
                            inversion H1; subst; clear H1. auto.
                        - destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                          inversion wf_int_pref'.
                          + now destruct prefix.
                          + destruct prefix as [|? []]; try discriminate.
                            inversion H; subst e; clear H.
                            inversion H0; subst; clear H0.
                            now auto.
                          + rewrite cats1 in H. apply rcons_inj in H. inversion H; subst; clear H.
                            inversion H1; subst; clear H1. auto.
                      }
                      + intros C0 _ ?; subst C0. simpl. (* lookup *)
                        pose proof (wfmem wf_mem Hprefix01) as [Hregs [Hnextcomp Hnotnextcomp]].
                        split; [| split; [| split]].
                        * by simplify_memory'.
                        * simplify_memory. simpl in Hnotnextcomp. specialize (Hnotnextcomp C' C'_b C'_next_e1).
                          destruct Hnotnextcomp.
                          -- destruct H as [? [? ?]]. eauto.
                          -- destruct H as [? [? ?]]. congruence.
                        * move=> b Hb //=.
                          destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                          inversion wf_int_pref'.
                          -- now destruct prefix.
                          -- destruct prefix as [|? []]; try discriminate.
                             now destruct prefix0.
                          -- rewrite cats1 in H. apply rcons_inj in H. inversion H; subst; clear H.
                             rewrite cats1 in H3. apply rcons_inj in H3. inversion H3; subst; clear H3.
                             inversion H1; subst; clear H1.
                             unfold Block.local in Hb.
                             destruct b as [| b']; first congruence.
                             eexists. split; [| split].
                             ++ simpl. rewrite shift_S_Some. reflexivity.
                             ++ simpl. intros off v' Hload.
                                specialize (Hnotnextcomp C' C'_b C'_next_e1).
                                destruct Hnotnextcomp as [[? [? ?]] | [? [? ?]]]; last congruence.
                                repeat match goal with
                                       | Hload: Memory.load ?mem' ?ptr' = Some ?v',
                                           Hstore: Memory.store ?mem ?ptr ?v = Some ?mem' |- _ =>
                                           erewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hstore) in Hload
                                       end.
                                destruct H2 as [Hshift0 Hblock0].
                                specialize (Hshift0 (S b')) as [? [Haddr [Hshift1 Hshift2]]]; eauto.
                                rewrite shift_S_Some in Haddr. inversion Haddr; subst; clear Haddr. simpl in *.
                                by specialize (Hshift1 _ _ Hload).
                             ++ simpl. intros off v' Hload.
                                specialize (Hnotnextcomp C' C'_b C'_next_e1).
                                destruct Hnotnextcomp as [[? [? ?]] | [? [? ?]]]; last congruence.
                                destruct H2 as [Hshift0 Hblock0].
                                specialize (Hshift0 (S b')) as [? [Haddr [Hshift1 Hshift2]]]; eauto.
                                rewrite shift_S_Some in Haddr. inversion Haddr; subst; clear Haddr. simpl in *.
                                specialize (Hshift2 _ _ Hload) as [v [? ?]].
                                by exists v; split; simplify_memory.
                                          * move=> b Hb //=.
                                            do 10 (erewrite Memory.next_block_store_stable; eauto).
                                            specialize (Hnotnextcomp C' C'_b C'_next_e1).
                                            destruct Hnotnextcomp as [[? [? ?]] | [? [? ?]]]; last congruence.
                                            destruct H1 as [Hshift0 Hblock0].
                                            destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                                            inversion wf_int_pref'.
                                            -- now destruct prefix.
                                            -- destruct prefix as [|? []]; try discriminate.
                                               now destruct prefix0.
                                            -- rewrite cats1 in H1. apply rcons_inj in H1. inversion H1; subst; clear H1.
                                               rewrite cats1 in H5. apply rcons_inj in H5. inversion H5; subst; clear H5.
                                               inversion H3; subst; clear H3. simpl in *.
                                               by specialize (Hblock0 b Hb).

                                          + intros C0 C0_b C0_neq.
                                            destruct (C0 == C) eqn:C0_C;
                                              move: C0_C => /eqP C0_C; [subst C0|].
                                            * (* C0 is C. We know it's initialized. *)
                                              left.
                                              pose proof (wfmem wf_mem Hprefix01) as [Hregs [Hnextcomp _]].
                                              specialize (Hnextcomp C C_b C_next_e1) as [Hinitflag [Hlocalbuf Hsteady']].
                                              { split; [| split; [| split]].
                                                - simplify_memory.
                                                - simplify_memory.
                                                - simpl.
                                                  intros b Hb.
                                                  unfold Block.local in Hb.
                                                  destruct b as [| b']; first congruence.
                                                  eexists. split; [| split].
                                                  ++ simpl. rewrite shift_S_Some. reflexivity.
                                                  ++ simpl. intros off v' Hload.
                                                     repeat match goal with
                                                            | Hload: Memory.load ?mem' ?ptr' = Some ?v',
                                                                Hstore: Memory.store ?mem ?ptr ?v = Some ?mem' |- _ =>
                                                                erewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hstore) in Hload
                                                            end.
                                                     destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                                                     inversion wf_int_pref'.
                                                     ** now destruct prefix.
                                                     ** destruct prefix as [|? []]; try discriminate.
                                                        now destruct prefix0.
                                                     ** rewrite cats1 in H. apply rcons_inj in H. inversion H. subst; clear H.
                                                        rewrite cats1 in H3. apply rcons_inj in H3. inversion H3; subst; clear H3.
                                                        inversion H1; subst; clear H1. simpl in *.
                                                        destruct Hsteady' as [Hshift0 Hblock0].
                                                        specialize (Hshift0 (S b')) as [? [Haddr [Hshift1 Hshift2]]]; eauto.
                                                        rewrite shift_S_Some in Haddr. inversion Haddr; subst; clear Haddr. simpl in *.
                                                        by specialize (Hshift1 _ _ Hload).
                                                  ++ simpl. intros off v' Hload.
                                                     destruct Hsteady' as [Hshift0 Hblock0].
                                                     specialize (Hshift0 (S b')) as [? [Haddr [Hshift1 Hshift2]]]; eauto.
                                                     rewrite shift_S_Some in Haddr. inversion Haddr; subst; clear Haddr. simpl in *.
                                                     destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                                                     inversion wf_int_pref'.
                                                     ** now destruct prefix0.
                                                     ** destruct prefix0 as [|? []]; try discriminate.
                                                     ** rewrite cats1 in H. apply rcons_inj in H. inversion H. subst; clear H.
                                                        rewrite cats1 in H3. apply rcons_inj in H3. inversion H3; subst; clear H3.
                                                        inversion H1; subst; clear H1. simpl in *.
                                                        specialize (Hshift2 _ _ Hload) as [v [? ?]].
                                                        by exists v; split; simplify_memory.
                                                                  - move=> b Hb //=.
                                                                    do 10 (erewrite Memory.next_block_store_stable; eauto).
                                                                    destruct Hsteady' as [Hshift0 Hblock0].
                                                                    destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                                                                    inversion wf_int_pref'.
                                                                    -- now destruct prefix.
                                                                    -- destruct prefix as [|? []]; try discriminate.
                                                                       now destruct prefix0.
                                                                    -- rewrite cats1 in H. apply rcons_inj in H. inversion H; subst; clear H.
                                                                       rewrite cats1 in H3. apply rcons_inj in H3. inversion H3; subst; clear H3.
                                                                       inversion H1; subst; clear H1. simpl in *.
                                                                       by specialize (Hblock0 b Hb).
                                              }

                                            * pose proof (wfmem wf_mem Hprefix01) as [Hregs [Hnextcomp Hnotnextcomp]].
                                              rewrite //= -C_next_e1 in Hnotnextcomp.
                                              specialize (Hnotnextcomp _ C0_b C0_C) as [Hsteady' | Hinitial].
                                              -- destruct Hsteady' as [Hinitflag [Hlocalbuf Hsteady']].
                                                 left. split; [| split].
                                                 ++ simplify_memory.
                                                 ++ simplify_memory.
                                                 ++ unfold postcondition_event_snapshot_steadystate
                                                      in *.
                                                    destruct Hsteady' as [Hsteady' Hnextblock].
                                                    split.
                                                    ** intros b Hlocal.
                                                       specialize (Hsteady' b Hlocal)
                                                         as [Cb [Hshift' [Hrename Hrename']]].
                                                       exists Cb. split; [| split].
                                                       --- exact Hshift'.
                                                       --- intros off v' Hload. simpl in *.
                                                           repeat match goal with
                                                                  | Hload: Memory.load ?mem' ?ptr' = Some ?v',
                                                                      Hstore: Memory.store ?mem ?ptr ?v = Some ?mem' |- _ =>
                                                                      erewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hstore) in Hload
                                                                  end.
                                                           specialize (Hrename off v' Hload)
                                                             as [v'' [Hload'' Hrename]].
                                                           exists v''. split; eauto.
                                                           destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                                                           inversion wf_int_pref'.
                                                           +++ now destruct prefix.
                                                           +++ destruct prefix as [|? []]; try discriminate.
                                                               now destruct prefix0.
                                                           +++ rewrite cats1 in H. apply rcons_inj in H. inversion H; subst; clear H.
                                                               rewrite cats1 in H3. apply rcons_inj in H3. inversion H3; subst; clear H3.
                                                               by inversion H1; subst; clear H1.
                                                       --- intros off v' Hload.
                                                           destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                                                           inversion wf_int_pref'.
                                                           +++ now destruct prefix.
                                                           +++ destruct prefix as [|? []]; try discriminate.
                                                               now destruct prefix0.
                                                           +++ rewrite cats1 in H. apply rcons_inj in H. inversion H; subst; clear H.
                                                               rewrite cats1 in H3. apply rcons_inj in H3. inversion H3; subst; clear H3.
                                                               inversion H1; subst; clear H1.

                                                               specialize (Hrename' off v' Hload)
                                                                 as [v'' [Hload'' Hrename']].
                                                               exists v''. split; simpl.
                                                               *** simplify_memory'. eauto.
                                                               *** eauto.
                                                    ** intros b Hnextb.
                                                       unfold Memory.next_block.
                                                       assert (asmp: mem0 C0 = mem8 C0).
                                                       {
                                                         Local Transparent Memory.store.
                                                         unfold Memory.store in *.
                                                         Local Opaque Memory.store.
                                                         simpl in *.

                                                         destruct (mem0 C) eqn:e0C; last discriminate.
                                                         destruct (mem C) eqn:eC; last discriminate.
                                                         destruct (mem1 C') eqn:e1C'; last discriminate.
                                                         destruct (mem1' C') eqn:e1'C'; last discriminate.
                                                         destruct (mem2 C') eqn:e2C'; last discriminate.
                                                         destruct (mem3 C') eqn:e3C'; last discriminate.
                                                         destruct (mem4 C') eqn:e4C'; last discriminate.
                                                         destruct (mem5 C') eqn:e5C'; last discriminate.
                                                         destruct (mem6 C') eqn:e6C'; last discriminate.
                                                         destruct (mem7 C') eqn:e7C'; last discriminate.

                                                         destruct (ComponentMemory.store s Block.local 0%Z
                                                                                         (Int (counter_value C (prefix ++ [:: ERetInform C ret_val mem' regs C'])))) eqn:eq1; last discriminate.
                                                         destruct (ComponentMemory.store s0 Block.local EXTCALL_offset (Int 1)) eqn:eq2; last discriminate.
                                                         destruct (ComponentMemory.store s1 Block.local 5%Z vcom) eqn:eq3; last discriminate.
                                                         destruct (ComponentMemory.store s2 Block.local 4%Z Undef) eqn:eq4; last discriminate.
                                                         destruct (ComponentMemory.store s3 Block.local 6%Z Undef) eqn:eq5; last discriminate.
                                                         destruct (ComponentMemory.store s4 Block.local 7%Z Undef) eqn:eq6; last discriminate.
                                                         destruct (ComponentMemory.store s5 Block.local 8%Z Undef) eqn:eq7; last discriminate.
                                                         destruct (ComponentMemory.store s6 Block.local 9%Z Undef) eqn:eq8; last discriminate.
                                                         destruct (ComponentMemory.store s7 Block.local 10%Z Undef) eqn:eq9; last discriminate.
                                                         destruct (ComponentMemory.store s8 Block.local EXTCALL_offset (Int 0)) eqn:eq10; last discriminate.
                                                         repeat match goal with
                                                                | H: Some _ = Some _ |- _ => inversion H; subst; clear H
                                                                end.
                                                         rewrite !setmE.
                                                         assert (C0 == C' = false) as rewr by now apply /eqP.
                                                         rewrite rewr.
                                                         assert (C0 == match e1 with
                                                                       | ECallInform _ _ _ _ _ C | ERetInform _ _ _ _ C |
                                                                         EConst C _ _ _ _ | EMov C _ _ _ _ | EBinop C _ _ _ _ _ _ |
                                                                         ELoad C _ _ _ _ | EStore C _ _ _ _ | EAlloc C _ _ _ _ => C
                                                                       end = false) as rewr' by now apply /eqP.
                                                         rewrite rewr'.
                                                         reflexivity.
                                                       }
                                                       rewrite <- asmp. simpl in Hnextb.
                                                       destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                                                       inversion wf_int_pref'.
                                                       --- now destruct prefix.
                                                       --- destruct prefix as [|? []]; try discriminate.
                                                           now destruct prefix0.
                                                       --- rewrite cats1 in H. apply rcons_inj in H. inversion H; subst; clear H.
                                                           rewrite cats1 in H3. apply rcons_inj in H3. inversion H3; subst; clear H3.
                                                           inversion H1; subst; clear H1. simpl in *.
                                                           by specialize (Hnextblock _ Hnextb).
                                              -- destruct Hinitial
                                                   as [Hinitflag [Hlocalbuf [
                                                             [[compMem [buf [He1 Hbuf]]]
                                                                Hintial2
                                                             ] Hnot_shared]
                                                   ]].
                                                 right. split; [| split; [| split]].
                                                 ++ simplify_memory.
                                                 ++ simplify_memory.
                                                 ++ unfold postcondition_event_snapshot_uninitialized
                                                      in *.
                                                    destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                                                    inversion wf_int_pref'.
                                                    ** now destruct prefix.
                                                    ** destruct prefix as [|? []]; try discriminate.
                                                       now destruct prefix0.
                                                    ** rewrite cats1 in H. apply rcons_inj in H. inversion H; subst; clear H.
                                                       rewrite cats1 in H3. apply rcons_inj in H3. inversion H3; subst; clear H3.
                                                       inversion H1; subst; clear H1. simpl in *.
                                                       split.
                                                       --- simpl. exists compMem, buf.
                                                           eauto.
                                                       ---

                                                         assert (asmp: mem0 C0 = mem8 C0).
                                                         {
                                                           Local Transparent Memory.store.
                                                           unfold Memory.store in *.
                                                           Local Opaque Memory.store.
                                                           simpl in *.

                                                           remember (match e1 with
                                                                     | ECallInform _ _ _ _ _ C | ERetInform _ _ _ _ C |
                                                                       EConst C _ _ _ _ | EMov C _ _ _ _ |
                                                                       EBinop C _ _ _ _ _ _ | ELoad C _ _ _ _ |
                                                                       EStore C _ _ _ _ | EAlloc C _ _ _ _ => C
                                                                     end) as C.

                                                           destruct (mem0 C) eqn:e0C; last (discriminate).
                                                           destruct (mem C) eqn:eC; last discriminate.
                                                           destruct (mem1 C') eqn:e1C'; last discriminate.
                                                           destruct (mem1' C') eqn:e1'C'; last discriminate.
                                                           destruct (mem2 C') eqn:e2C'; last discriminate.
                                                           destruct (mem3 C') eqn:e3C'; last discriminate.
                                                           destruct (mem4 C') eqn:e4C'; last discriminate.
                                                           destruct (mem5 C') eqn:e5C'; last discriminate.
                                                           destruct (mem6 C') eqn:e6C'; last discriminate.
                                                           destruct (mem7 C') eqn:e7C'; last discriminate.

                                                           destruct (ComponentMemory.store s Block.local 0%Z
                                                                                           (Int
                                                                                              (counter_value C
                                                                                                             ((prefix0 ++ [:: e1]) ++
                                                                                                                                   [:: ERetInform C
                                                                                                                                       (Machine.Intermediate.Register.get Machine.R_COM
                                                                                                                                                                          (register_file_of_event_inform e1))
                                                                                                                                       (mem_of_event_inform e1)
                                                                                                                                       (Machine.Intermediate.Register.invalidate
                                                                                                                                          (register_file_of_event_inform e1)) C'])))) eqn:eq1; last discriminate.
                                                           destruct (ComponentMemory.store s0 Block.local EXTCALL_offset (Int 1)) eqn:eq2; last discriminate.
                                                           destruct (ComponentMemory.store s1 Block.local 5%Z vcom) eqn:eq3; last discriminate.
                                                           destruct (ComponentMemory.store s2 Block.local 4%Z Undef) eqn:eq4; last discriminate.
                                                           destruct (ComponentMemory.store s3 Block.local 6%Z Undef) eqn:eq5; last discriminate.
                                                           destruct (ComponentMemory.store s4 Block.local 7%Z Undef) eqn:eq6; last discriminate.
                                                           destruct (ComponentMemory.store s5 Block.local 8%Z Undef) eqn:eq7; last discriminate.
                                                           destruct (ComponentMemory.store s6 Block.local 9%Z Undef) eqn:eq8; last discriminate.
                                                           destruct (ComponentMemory.store s7 Block.local 10%Z Undef) eqn:eq9; last discriminate.
                                                           destruct (ComponentMemory.store s8 Block.local EXTCALL_offset (Int 0)) eqn:eq10; last discriminate.
                                                           repeat match goal with
                                                                  | H: Some _ = Some _ |- _ => inversion H; subst; clear H
                                                                  end.
                                                           rewrite !setmE.
                                                           assert (C0 == C' = false) as rewr by now apply /eqP.
                                                           rewrite rewr.
                                                           assert (C0 == match e1 with
                                                                         | ECallInform _ _ _ _ _ C | ERetInform _ _ _ _ C |
                                                                           EConst C _ _ _ _ | EMov C _ _ _ _ | EBinop C _ _ _ _ _ _ |
                                                                           ELoad C _ _ _ _ | EStore C _ _ _ _ | EAlloc C _ _ _ _ => C
                                                                         end = false) as rewr' by now apply /eqP.
                                                           rewrite rewr'.
                                                           reflexivity.
                                                         }
                                                         by rewrite <- asmp.
                                                 ++
                                                   destruct p_gens_t as [? G].
                                                   rewrite Et project_non_inform_append in G.
                                                   simpl in G. unfold Eapp in G.
                                                   replace ((ERet C ret_val mem' C' :: project_non_inform suffix)) with ([:: ERet C ret_val mem' C'] ++ project_non_inform suffix) in G; last reflexivity.
                                                   setoid_rewrite app_assoc in G.
                                                   apply star_app_inv in G as [? [G _]];
                                                     last by apply CS.CS.singleton_traces_non_inform.

                                                   setoid_rewrite cats1 in G.
                                                   intros b Hshared.
                                                   pose proof CSInvariants.CSInvariants.not_executing_can_not_share
                                                        _ _ _ _ C0 b
                                                        wf_p_interm closed_p_interm G as Hlemma.
                                                   simpl in *.
                                                   subst prefix. rewrite -cats1 in Hnot_shared.
                                                   specialize (Hlemma C0_C Hnot_shared).
                                                   rewrite -!cats1 project_non_inform_append in Hlemma.
                                                   unfold Eapp in Hlemma. setoid_rewrite cats1 in Hlemma.

                                                   setoid_rewrite <- project_non_inform_append in Hlemma.
                                                   rewrite -!cats1 project_non_inform_append in Hshared.
                                                   setoid_rewrite cats1 in Hshared.
                                                   contradiction.
                                          - move=> ptr cid bid off.
                                            destruct (Pointer.eq ptr (Permission.data, C', Block.local, 1%Z)) eqn:eq_ptr;
                                              move: eq_ptr =>
                                                       /Pointer.eqP eq_ptr; subst;
                                                       [erewrite Memory.load_after_store_eq; eauto; try by []
                                                       | erewrite Memory.load_after_store_neq; eauto; clear eq_ptr].
                                            destruct (Pointer.eq ptr (Permission.data, C', Block.local, 10%Z)) eqn:eq_ptr;
                                              move: eq_ptr =>
                                                       /Pointer.eqP eq_ptr; subst;
                                                       [erewrite Memory.load_after_store_eq; eauto; try by []
                                                       | erewrite Memory.load_after_store_neq; eauto; clear eq_ptr].
                                            destruct (Pointer.eq ptr (Permission.data, C', Block.local, 9%Z)) eqn:eq_ptr;
                                              move: eq_ptr =>
                                                       /Pointer.eqP eq_ptr; subst;
                                                       [erewrite Memory.load_after_store_eq; eauto; try by []
                                                       | erewrite Memory.load_after_store_neq; eauto; clear eq_ptr].
                                            destruct (Pointer.eq ptr (Permission.data, C', Block.local, 8%Z)) eqn:eq_ptr;
                                              move: eq_ptr =>
                                                       /Pointer.eqP eq_ptr; subst;
                                                       [erewrite Memory.load_after_store_eq; eauto; try by []
                                                       | erewrite Memory.load_after_store_neq; eauto; clear eq_ptr].
                                            destruct (Pointer.eq ptr (Permission.data, C', Block.local, 7%Z)) eqn:eq_ptr;
                                              move: eq_ptr =>
                                                       /Pointer.eqP eq_ptr; subst;
                                                       [erewrite Memory.load_after_store_eq; eauto; try by []
                                                       | erewrite Memory.load_after_store_neq; eauto; clear eq_ptr].
                                            destruct (Pointer.eq ptr (Permission.data, C', Block.local, 6%Z)) eqn:eq_ptr;
                                              move: eq_ptr =>
                                                       /Pointer.eqP eq_ptr; subst;
                                                       [erewrite Memory.load_after_store_eq; eauto; try by []
                                                       | erewrite Memory.load_after_store_neq; eauto; clear eq_ptr].
                                            destruct (Pointer.eq ptr (Permission.data, C', Block.local, 4%Z)) eqn:eq_ptr;
                                              move: eq_ptr =>
                                                       /Pointer.eqP eq_ptr; subst;
                                                       [erewrite Memory.load_after_store_eq; eauto; try by []
                                                       | erewrite Memory.load_after_store_neq; eauto; clear eq_ptr].
                                            destruct (Pointer.eq ptr (Permission.data, C', Block.local, 5%Z)) eqn:eq_ptr;
                                              move: eq_ptr =>
                                                       /Pointer.eqP eq_ptr; subst;
                                                       [erewrite Memory.load_after_store_eq; eauto; try by []
                                                       | erewrite Memory.load_after_store_neq; eauto; clear eq_ptr].
                                            eapply wfmem in wf_mem as [G ?]; last eauto.
                                            specialize (G Machine.R_COM _ Logic.eq_refl) as [v1' [v2' G]].
                                            destruct G as [G1 [G2 G3]].
                                            rewrite G1 in Hcom. inversion Hcom; subst; clear Hcom.
                                            destruct vcom as [| [[[[]]]] |]; try discriminate.
                                            rewrite /all_zeros_shift /uniform_shift //=
                                                    /rename_addr_option /sigma_shifting_wrap_bid_in_addr
                                                    /sigma_shifting_lefttoright_addr_bid
                                                    /sigma_shifting_lefttoright_option in G2.
                                            destruct i0; try discriminate. simpl in G2. intros R; inversion R; by [].
                                            destruct (Pointer.eq ptr (Permission.data, next_comp_of_event e1,
                                                                       Block.local, EXTCALL_offset)) eqn:eq_ptr;
                                              move: eq_ptr =>
                                                       /Pointer.eqP eq_ptr; subst;
                                                       [erewrite Memory.load_after_store_eq; eauto; try by []
                                                       | erewrite Memory.load_after_store_neq; eauto; clear eq_ptr].
                                            destruct (Pointer.eq ptr (Permission.data, next_comp_of_event e1,
                                                                       Block.local, 0%Z)) eqn:eq_ptr;
                                              move: eq_ptr =>
                                                       /Pointer.eqP eq_ptr; subst;
                                                       [erewrite Memory.load_after_store_eq; eauto; try by []
                                                       | erewrite Memory.load_after_store_neq; eauto; clear eq_ptr].
                                            by eapply wfmem_no_private_ptr; eauto.
                  }

              - intros mem1 Hmem1' Hmem1 Hmem2 arg.
                simpl in Htop. destruct Htop as [[? ?] Htop]. subst C_ k_.
                specialize (IHtop Htop).
                specialize (IHtop mem1 Hmem1' Hmem1 Hmem2 saved). destruct IHtop as [cs' [StarRet wf_cs']].
                exists cs'. split; trivial.
                eapply star_step; try eassumption.
                * by apply/CS.eval_kstep_sound; rewrite /= eqxx.
                * reflexivity. }

            (* Now we can conclude *)

            destruct Star_ret as [s' [cs' [Star_ret [mem_cs' wf_cs']]]].
            exists (ERetInform C vcom mem1 regs C').
            eexists. eexists. split; last split.
            eapply star_trans; eauto.
            eauto.
            {
              rewrite project_non_inform_append. simpl.
              replace (project_non_inform prefix ** [:: ERet (cur_comp s) ret_val mem' C'])
                with (project_non_inform prefix ++ [:: ERet (cur_comp s) ret_val mem' C']); last by reflexivity.
              rewrite 2!cats1.
              eapply rcons_renames_rcons_option; eauto.
              - inversion Hshift; eauto.
              - intros [Cb b] Hshared.
                split.
                + rewrite /all_zeros_shift /uniform_shift
                          /event_renames_event_at_shared_addr //=.
                  destruct cs'. simpl in mem_cs'; subst s_memory.
                  inversion wf_cs' as [? ? ? ? ? ? ? ? ? ? ? ? ? ? wf_mem8 ?].
                  subst C0 stk0 mem9 s_cont s_expr s_arg k exp s_component.
                  eapply wfmem in wf_mem8 as [wf_regs [wf_mem8 wf_mem8']];
                    last reflexivity.
                  simpl in wf_regs, wf_mem8, wf_mem8'.
                  unfold postcondition_steady_state in wf_mem8.
                  unfold postcondition_event_snapshot_steadystate in wf_mem8.
                  case Cb_C: (Cb == C'); move: Cb_C => /eqP Cb_C; [subst Cb |].
                  * specialize (wf_mem8 _ C'_b Logic.eq_refl) as [_ [_ [Hshift1 _]]].
                    unfold well_formed_memory_snapshot_steadystate_shift in Hshift1.
                    unfold memory_shifts_memory_at_shared_addr in Hshift1.
                    unfold all_zeros_shift, uniform_shift in Hshift1.
                    simpl in Hshift1.
                    specialize (Hshift1 (S b)).
                    unfold memory_renames_memory_at_shared_addr in *.
                    eexists (C', S b).
                    split; [| split].
                    -- rewrite /sigma_shifting_wrap_bid_in_addr. simpl.
                       by rewrite ssrnat.subn0 ssrnat.addn1.
                    -- intros off v Hload; simpl in *.
                       destruct Hshift1 as [addr' [Hshift1 [Hshift2 Hshift3]]];
                         first easy.
                       rewrite /sigma_shifting_wrap_bid_in_addr //= in Hshift1.
                       rewrite ssrnat.subn1 ssrnat.addn0 in Hshift1.
                       inversion Hshift1; subst addr'.
                       simpl in Hshift3.
                       specialize (Hshift3 _ _ Hload) as [? [? ?]].
                       eexists; split.
                       ++ repeat match goal with
                                 | Hload: Memory.load ?mem' ?ptr' = Some ?v',
                                     Hstore: Memory.store ?mem ?ptr ?v = Some ?mem' |- _ =>
                                     erewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hstore) in Hload
                                 end.
                          by simplify_memory.
                       ++ destruct x; simpl in *; try by inversion H0; subst v.
                          destruct t0 as [[[[|] ?] ?] ?]; simpl in *.
                          by inversion H0.
                          destruct i0; inversion H0; subst v.
                          by rewrite //= ssrnat.subn1 ssrnat.addn0 ssrnat.subn0 ssrnat.addn1.
                    -- intros off v Hload; simpl in *.
                       destruct Hshift1 as [addr' [Hshift1 [Hshift2 Hshift3]]];
                         first easy.
                       rewrite /sigma_shifting_wrap_bid_in_addr //= in Hshift1.
                       rewrite ssrnat.subn1 ssrnat.addn0 in Hshift1.
                       inversion Hshift1; subst addr'.
                       simpl in Hshift2.
                       assert (Hload': Memory.load mem8 (Permission.data, C', S b, off) = Some v)
                         by simplify_memory.
                       specialize (Hshift2 _ _ Hload') as [? [? ?]].
                       eexists; split.
                       ++ eassumption.
                       ++ destruct v; simpl in *; try by inversion H0; subst x.
                          destruct t0 as [[[[|] ?] ?] ?]; simpl in *.
                          by inversion H0.
                          destruct i0; inversion H0; subst x.
                          by rewrite //= ssrnat.subn1 ssrnat.addn0 ssrnat.subn0 ssrnat.addn1.
                  * (* Prove good_trace something. Get from Hshared that there's a
                     * load and [1 <= b]. Now we can get a contradiction to
                     * [postcondition_uninitialized] *)
                    (* *)
                    exists (Cb, S b).
                    split.
                    -- rewrite /all_zeros_shift /uniform_shift //=.
                       rewrite /sigma_shifting_wrap_bid_in_addr //=.
                       by rewrite ssrnat.subn0 ssrnat.addn1.
                    --

                      assert (Hwf_p: Source.well_formed_program p).
                      {
                        eapply well_formed_events_well_formed_program
                          in wf_events as [p_wf [Hp_wf1 Hp_wf2]]; eauto.
                        + erewrite Hprog_of_trace in Hp_wf1. inversion Hp_wf1.
                          by subst p_wf.
                        + by eapply domm_t_procs_exported_procedures_of_trace.
                      }
                      assert (Hclosed_p: Source.closed_program p).
                      {
                        by eapply closed_program_of_trace; eauto.
                      }

                      assert (Star_init_ret:
                               Star
                                 (CS.sem p)
                                 (CS.initial_machine_state p)
                                 (prefix' ++ [:: ERet C vcom mem1 C'])
                                 [CState cur_comp s',
                                   s_stack,
                                   mem8,
                                   Kstop,
                                   expr_of_trace
                                     (cur_comp s') P0
                                     (comp_subtrace (cur_comp s') t),
                                   arg0]
                             ).
                      {
                        eapply star_trans.
                        - eapply Star0.
                        - eapply star_trans; eauto.
                          eapply star_trans; eauto.
                        - reflexivity.
                      }
                      split; intros ? ? Hload.
                      ++ simpl in *.
                         assert (HCb: component_buffer Cb).
                         {
                           (** This essentially follows IF we knew that the
                          intermediate trace came from an intermediate execution.
                          Then, we can possibly use a lemma in CSInvariants? *)

                           unfold component_buffer.
                           replace intf with (Machine.Intermediate.prog_interface p_interm).
                           destruct p_gens_t as [? G].
                           rewrite Et project_non_inform_append in G.
                           simpl in G. unfold Eapp in G.
                           replace ((ERet (cur_comp s) ret_val mem' C' :: project_non_inform suffix)) with ([:: ERet (cur_comp s) ret_val mem' C'] ++ project_non_inform suffix) in G; last reflexivity.
                           setoid_rewrite app_assoc in G.
                           apply star_app_inv in G as [? [G _]].
                           setoid_rewrite cats1 in G.
                           eapply CSInvariants.CSInvariants.load_Some_component_buffer with
                             (ptr := (Permission.data, Cb, b, offset))
                             (e := (ERet (cur_comp s) ret_val mem' C')); eauto.
                           apply CS.CS.singleton_traces_non_inform.
                         }
                         specialize (wf_mem8' _ HCb Cb_C) as
                           [[? [? [? ?]]] | [? [? [[[compMem [? HcompMem]] ?] Hnot_shared]]] ].
                         ** assert (Hnoteq: S b <> Block.local).
                            { by unfold Block.local. }
                            specialize (steadysnap_shift0 _ Hnoteq)
                              as [[C_ b_] [Hb_ [mem8_mem' mem'_mem8]]].
                            rewrite shift_S_Some in Hb_.
                            inversion Hb_; subst C_ b_; clear Hb_.
                            simpl in *.
                            specialize (mem'_mem8 _ _ Hload) as [v' [Hloadv' Hv']].
                            exists v'. split.
                            ---
                              simplify_memory_in_assm.
                            --- specialize (shift_value_option_symmetry
                                              (fun=> 1) (fun=> 0)) as Lem.
                                unfold shift_value_option,
                                  sigma_shifting_wrap_bid_in_addr,
                                  sigma_shifting_lefttoright_addr_bid,
                                  rename_addr_option in *.
                                by eapply Lem.
                         ** simpl in *. destruct HcompMem as [HcompMem [? [Hnext ?]]].
                            (** Intuitively, there should be a contradiction. *)
                            (** In particular, ** is the case where Cb is not *)
                            (** initialized. What we know about Cb is that it *)
                            (** shared an address and that this address also was *)
                            (** loaded from memory (Hload). *)
                            specialize (Hnot_shared b).
                            rewrite -!cats1 project_non_inform_append /= in Hnot_shared.
                            setoid_rewrite cats1 in Hnot_shared.
                            apply Hnot_shared in Hshared.
                            contradiction.
                      ++ simpl in *.
                         assert (Hload': Memory.load
                                           mem8
                                           (Permission.data, Cb, S b, offset) = Some v').
                         {
                           by simplify_memory.
                         }
                         (** Need to know component_buffer Cb. *)
                         (** Intuitively, we should know it from Hload *)
                         (** Knowing it from Hload should be a source "CSInvariant". *)

                         assert (HCb: component_buffer Cb).
                         {
                           unfold component_buffer.
                           replace intf with (Machine.Intermediate.prog_interface p_interm).

                           specialize (@CS.CS.load_component_prog_interface_addr
                                         _ Hwf_p Hclosed_p _ _ _
                                         (Permission.data, Cb, S b, offset) v'
                                         Logic.eq_refl Star_init_ret
                                      ) as G'.
                           simpl in *. rewrite p_interm_intf.
                           by subst p; intuition.
                         }


                         specialize (wf_mem8' _ HCb Cb_C) as
                           [[? [? [? ?]]] | [? [? [[[compMem [? HcompMem]] ?] Hnot_shared]]] ].
                         ** assert (Hnoteq: S b <> Block.local).
                            { by unfold Block.local. }
                            specialize (steadysnap_shift0 _ Hnoteq)
                              as [[C_ b_] [Hb_ [mem8_mem' mem'_mem8]]].
                            rewrite shift_S_Some in Hb_.
                            inversion Hb_; subst C_ b_; clear Hb_.
                            simpl in *.
                            specialize (mem8_mem' _ _ Hload') as [v'' [Hloadv' Hv']].
                            exists v''. split.
                            --- assumption.
                            --- specialize (shift_value_option_symmetry
                                              (fun=> 1) (fun=> 0)) as Lem.
                                unfold shift_value_option,
                                  sigma_shifting_wrap_bid_in_addr,
                                  sigma_shifting_lefttoright_addr_bid,
                                  rename_addr_option in *.
                                by eapply Lem.
                         ** (** Hshared =/= Hnot_shared*)
                           rewrite -cats1 project_non_inform_append in Hnot_shared.
                           setoid_rewrite cats1 in Hnot_shared.
                           by apply Hnot_shared in Hshared.
                + exists (Cb, S b).
                  split.
                  * rewrite /all_zeros_shift /uniform_shift //=.
                    rewrite /sigma_shifting_wrap_bid_in_addr //=.
                    by rewrite ssrnat.subn0 ssrnat.addn1.
                  * inversion wf_cs' as [? ? ? ? ? ? ? ? ? ? ? ? ? ? wf_mem8 ?].
                    subst C0 k exp cs'.
                    eapply wfmem in wf_mem8 as [wf_regs [wf_mem8 wf_mem8']];
                      last reflexivity.
                    eapply addr_shared_so_far_inv_1 with (mem := mem0); eauto.
                    -- intros. by simplify_memory'.
                    -- simpl.
                       unfold all_zeros_shift, uniform_shift.
                       destruct (wf_regs Machine.R_COM _ Logic.eq_refl) as [vcom' [newarg' [G1 [G2 G3]]]].
                       simpl in *.
                       assert (vcom' = vcom).
                       { subst.
                         rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem8) in G1; last (unfold EXTCALL_offset; congruence).
                         rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem7) in G1; last congruence.
                         rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem6) in G1; last congruence.
                         rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem5) in G1; last congruence.
                         rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem4) in G1; last congruence.
                         rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem3) in G1; last congruence.
                         rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem2) in G1; last congruence.
                         rewrite (Memory.load_after_store_eq _ _ _ _ Hmem1') in G1; congruence. } subst vcom'.
                       assert (newarg' = ret_val).
                       { subst.
                         apply ipref_evsteps in wf_int_pref'.
                         rewrite cats1 in wf_int_pref'.
                         inversion wf_int_pref'. now destruct prefix0.
                         destruct prefix0. simpl in *. subst. congruence.
                         now destruct prefix0.
                         find_rcons_rcons. inversion H1; subst; eauto.
                       } subst.
                       auto.
                    -- subst.
                       eapply wfmem in wf_mem; last reflexivity.
                       destruct wf_mem as [_ [wf_mem _]].
                       intros; subst; simpl in *.
                       unfold postcondition_steady_state, postcondition_event_snapshot_steadystate in wf_mem.
                       specialize (wf_mem _ C_b C_next_e1) as [_ [_ [G _]]].
                       intros [| b'] not_local; first (unfold Block.local in not_local; congruence).
                       specialize (G _ not_local). destruct G as [addr [G1 [G2 G3]]].
                       eexists; split; last split; eauto.
                       ++ intros offset v Hload.
                          specialize (G2 _ _ Hload) as [v' [Hload' Hren]].
                          inversion wf_int_pref' as [U1 U2].
                          rewrite !cats1 in U1.
                          inversion U1.
                          ** now destruct prefix0.
                          ** now destruct prefix0 as [| ? []].
                          ** find_rcons_rcons. find_rcons_rcons.
                             inversion H6; subst; clear H6. eauto.
                       ++ intros offset v Hload.
                          inversion wf_int_pref' as [U1 U2].
                          rewrite !cats1 in U1.
                          inversion U1.
                          ** now destruct prefix0.
                          ** now destruct prefix0 as [| ? []].
                          ** find_rcons_rcons. find_rcons_rcons.
                             inversion H6; subst; clear H6. eauto.
                    -- subst.
                       eapply wfmem in wf_mem; last reflexivity.
                       destruct wf_mem as [_ [wf_mem1 wf_mem2]].
                       intros C0 C0_b.
                       destruct (C0 == next_comp_of_event e1) eqn:eC0;
                         move: eC0 => /eqP eC0; subst.
                       ++ left.
                          specialize (wf_mem1 _ C0_b Logic.eq_refl) as [_ [_ [G _]]].
                          { intros [| b'] not_local; first (unfold Block.local in not_local; congruence).
                            specialize (G _ not_local). destruct G as [addr [G1 [G2 G3]]].
                            eexists; split; last split; eauto.
                            ++ intros offset v Hload.
                               specialize (G2 _ _ Hload) as [v' [Hload' Hren]].
                               inversion wf_int_pref' as [U1 U2].
                               rewrite !cats1 in U1.
                               inversion U1.
                               ** now destruct prefix0.
                               ** now destruct prefix0 as [| ? []].
                               ** find_rcons_rcons. find_rcons_rcons.
                                  inversion H1; subst; clear H1. eauto.
                            ++ intros offset v Hload.
                               inversion wf_int_pref' as [U1 U2].
                               rewrite !cats1 in U1.
                               inversion U1.
                               ** now destruct prefix0.
                               ** now destruct prefix0 as [| ? []].
                               ** find_rcons_rcons. find_rcons_rcons.
                                  inversion H1; subst; clear H1. eauto. }
                       ++ specialize (wf_mem2 C0 C0_b eC0) as [wf_mem2 | wf_mem2].
                          ** left. destruct wf_mem2 as [_ [_ [G _]]].
                             { intros [| b'] not_local; first (unfold Block.local in not_local; congruence).
                               specialize (G _ not_local). destruct G as [addr [G1 [G2 G3]]].
                               eexists; split; last split; eauto.
                               ++ intros offset v Hload.
                                  specialize (G2 _ _ Hload) as [v' [Hload' Hren]].
                                  inversion wf_int_pref' as [U1 U2].
                                  rewrite !cats1 in U1.
                                  inversion U1.
                                  ** now destruct prefix0.
                                  ** now destruct prefix0 as [| ? []].
                                  ** find_rcons_rcons. find_rcons_rcons.
                                     inversion H1; subst; clear H1. eauto.
                               ++ intros offset v Hload.
                                  inversion wf_int_pref' as [U1 U2].
                                  rewrite !cats1 in U1.
                                  inversion U1.
                                  ** now destruct prefix0.
                                  ** now destruct prefix0 as [| ? []].
                                  ** find_rcons_rcons. find_rcons_rcons.
                                     inversion H1; subst; clear H1. eauto. }
                          ** right.
                             destruct wf_mem2 as [_ [_ [_ G]]].
                             now rewrite cats1.
                    -- intros C0 b0 C0_b not_eq not_shared shared.
                       assert (inv_mem: CSInvariants.CSInvariants.wf_mem_wrt_t_pc
                                          (mem_of_event_inform e1)
                                          (project_non_inform (prefix0 ++ [:: e1]))
                                          C).
                       { destruct p_gens_t_inform as [x star].
                         rewrite Et in star.
                         subst.
                         eapply star_app_inv in star as [x0 [star1 _]];
                           last eapply CS.CS.singleton_traces_inform.
                         eapply CSInvariants.CSInvariants.wf_state_wf_mem; eauto.
                         eapply CSInvariants.CSInvariants.is_prefix_wf_state_t; eauto.
                         eapply CS.CS.star_sem_inform_star_sem_non_inform. eauto.
                         erewrite CS.CS.starR_memory_of_event_inform; first by reflexivity.
                         eapply star_iff_starR. rewrite cats1 in star1. simpl in star1. eauto.
                         erewrite <- CS.CS.starR_next_comp_of_event_inform. eauto.
                         eapply star_iff_starR. rewrite cats1 in star1. simpl in star1. eauto. }
                       assert (inv_regs: CSInvariants.CSInvariants.wf_reg_wrt_t_pc
                                           (register_file_of_event_inform e1)
                                           (project_non_inform (prefix0 ++ [:: e1]))
                                           C).
                       { destruct p_gens_t_inform as [x star].
                         rewrite Et in star.
                         subst.
                         eapply star_app_inv in star as [x0 [star1 _]];
                           last eapply CS.CS.singleton_traces_inform.
                         eapply CSInvariants.CSInvariants.wf_state_wf_reg; eauto.
                         eapply CSInvariants.CSInvariants.is_prefix_wf_state_t; eauto.
                         eapply CS.CS.star_sem_inform_star_sem_non_inform. eauto.
                         erewrite CS.CS.starR_register_file_of_event_inform; first by reflexivity.
                         eapply star_iff_starR. rewrite cats1 in star1. simpl in star1. eauto.
                         erewrite <- CS.CS.starR_next_comp_of_event_inform. eauto.
                         eapply star_iff_starR. rewrite cats1 in star1. simpl in star1. eauto. }
                       subst.
                       clear -inv_mem inv_regs shared not_shared not_eq wf_int_pref'.
                       inversion shared; subst; clear shared.
                       ++ find_rcons_rcons. simpl in H1.
                          remember (C0, b0) as addr.
                          rewrite -Heqaddr in H1.
                          remember (addr_of_value ret_val) as addr_set.
                          generalize dependent b0. generalize dependent C0. generalize dependent ret_val.
                          induction H1.
                          ** intros new_arg wf_int_pref' eq_addr_set C0 C0_cur b0 eq_addr; subst.
                             simpl in H. destruct new_arg as [| [[[[]]]] |]; try discriminate.
                             simpl in H. rewrite in_fset1 in H.
                             move: H => /eqP H. inversion H; subst; clear H.
                             unfold CSInvariants.CSInvariants.wf_reg_wrt_t_pc in inv_regs.
                             inversion wf_int_pref' as [U1 _].
                             rewrite !cats1 in U1.
                             inversion U1.
                             --- now destruct prefix0.
                             --- now destruct prefix0 as [| ? []].
                             --- find_rcons_rcons. find_rcons_rcons.
                                 inversion H1; subst; clear H1. simpl in *.
                                 specialize (inv_regs _ _ H9 Logic.eq_refl).
                                 inversion inv_regs; subst; clear inv_regs.
                                 +++ unfold C in C0_cur. contradiction.
                                 +++ contradiction.
                          ** intros new_arg wf_int_pref' eq_addr_set C0 C0_cur b0 eq_addr; subst.
                             apply In_in in H0.
                             apply ComponentMemory.load_block_load in H0 as [? [i Hload']].
                             assert (Hload: Memory.load mem' (Permission.data, cid, bid, i) =
                                              Some (Ptr (Permission.data, C0, b0, x))).
                             { Local Transparent Memory.load.
                               unfold Memory.load. simpl. rewrite H. assumption.
                               Local Opaque Memory.load. }
                             inversion wf_int_pref' as [U1 _].
                             rewrite !cats1 in U1.
                             inversion U1.
                             --- now destruct prefix0.
                             --- now destruct prefix0 as [| ? []].
                             --- find_rcons_rcons. find_rcons_rcons.
                                 inversion H3; subst; clear H3. simpl in *.
                                 specialize (inv_mem _ _ Hload Logic.eq_refl).
                                 inversion inv_mem; subst; clear inv_mem.
                                 (* CSInvariants.CSInvariants.wf_load *)
                                 +++ simpl in *. subst.
                                     specialize (IHReachable H3 _ wf_int_pref').
                                     eapply IHReachable; eauto.
                                 +++ simpl in *. subst. contradiction.
                                 +++ simpl in *. subst. contradiction.
                       ++ find_rcons_rcons. simpl in H2.
                          remember (C0, b0) as addr.
                          rewrite -Heqaddr in H2.
                          remember (fset1 addr') as addr_set.
                          generalize dependent b0. generalize dependent C0. generalize dependent addr'.
                          induction H2.
                          ** intros addr' shared eq_addr_set C0 C0_cur b0 eq_addr; subst.
                             simpl in H. destruct addr' as [cid bid].
                             simpl in H. rewrite in_fset1 in H.
                             move: H => /eqP H. inversion H; subst; clear H.
                             contradiction.
                          ** intros addr' shared eq_addr_set C0 C0_cur b0 eq_addr; subst.
                             apply In_in in H0.
                             apply ComponentMemory.load_block_load in H0 as [? [i Hload']].
                             assert (Hload: Memory.load mem' (Permission.data, cid, bid, i) =
                                              Some (Ptr (Permission.data, C0, b0, x))).
                             { Local Transparent Memory.load.
                               unfold Memory.load. simpl. rewrite H. assumption.
                               Local Opaque Memory.load. }
                             inversion wf_int_pref' as [U1 _].
                             rewrite !cats1 in U1.
                             inversion U1.
                             --- now destruct prefix0.
                             --- now destruct prefix0 as [| ? []].
                             --- find_rcons_rcons. find_rcons_rcons.
                                 inversion H3; subst; clear H3. simpl in *.
                                 specialize (inv_mem _ _ Hload Logic.eq_refl).
                                 inversion inv_mem; subst; clear inv_mem.
                                 (* CSInvariants.CSInvariants.wf_load *)
                                 +++ simpl in *. subst.
                                     eapply IHReachable; eauto.
                                 +++ simpl in *. subst. contradiction.
                                 +++ simpl in *. subst. contradiction.
                    -- intros C0 b0 o v Hload. unfold component_buffer.
                       (* Use p_interm and p_gens_t. *)
                       (* and (CS.CS.comes_from_initial_state_mem_domm _ intf). *)
                       destruct p_gens_t_inform as [x star].
                       rewrite Et in star.
                       subst.
                       eapply star_app_inv in star as [x0 [star1 _]];
                         last eapply CS.CS.singleton_traces_inform.

                       rewrite <- (CS.CS.comes_from_initial_state_mem_domm x0 intf); eauto.
                       Local Transparent Memory.load.
                       unfold Memory.load in Hload. simpl in Hload.
                       destruct (mem' C0) eqn:mem'_C0; last discriminate.
                       erewrite <- CS.CS.starR_memory_of_event_inform.
                       inversion wf_int_pref' as [U1 _].
                       rewrite !cats1 in U1.
                       inversion U1.
                       --- now destruct prefix0.
                       --- now destruct prefix0 as [| ? []].
                       --- find_rcons_rcons. find_rcons_rcons.
                           inversion H1; subst; clear H1. simpl in *.
                           apply /dommP. eexists; eauto.
                       --- eapply star_iff_starR. rewrite cats1 in star1. simpl in star1. eauto.
                       --- unfold CS.CS.comes_from_initial_state.
                           eapply Machine.Intermediate.cprog_main_existence in closed_p_interm as [? [? ?]].
                           eexists; eexists; eexists; split. eauto.
                           split; eauto.
                           split; eauto.
                           split; eauto. reflexivity.
                    -- eapply traces_rename_each_other_option_symmetric. reflexivity.
                       inversion Hshift; eauto.
              - intros [Cb b] Hshared.

                destruct b.
                ++ exfalso.
                   assert (load_in_intf: forall ptr v,
                              Memory.load mem0 ptr = Some v ->
                              Pointer.component ptr \in domm intf).
                   {
                     eapply CS.comes_from_initial_state_mem_domm in Star0; eauto.
                     - subst p. simpl in Star0.  rewrite <- Star0.
                       now eapply CS.load_some_in_domm.
                     - eapply well_formed_events_well_formed_program
                         in wf_events as [p_wf [Hp_wf1 Hp_wf2]]; eauto.
                       + erewrite Hprog_of_trace in Hp_wf1. inversion Hp_wf1.
                         by subst p_wf.
                       + by eapply domm_t_procs_exported_procedures_of_trace.
                     - eapply closed_program_of_trace.
                       subst p. by erewrite Hprog_of_trace.
                     - reflexivity.
                   }
                   inversion Hshared; subst; clear Hshared.
                   { find_rcons_rcons. simpl in H1.
                     clear -wf_mem Hmem Hmem1 wf_int_pref' Hcom H1 C_next_e1 C_b load_in_intf.
                     remember (Cb, 0) as addr. setoid_rewrite <- Heqaddr in H1.
                     remember (addr_of_value vcom) as addr_set.
                     generalize dependent Cb. generalize dependent vcom.
                     induction H1.
                     - intros vcom Hload eq_addr_set Cb eq_addr; subst.
                       destruct vcom as [| [[[[]]]] |]; try by rewrite /= in_fset0 in H.
                       simpl in H. rewrite in_fset1 in H.
                       move: H => /eqP H; inversion H; subst; clear H.
                       eapply wfmem in wf_mem; last reflexivity.
                       destruct wf_mem as [wf_mem [_ _]].
                       specialize (wf_mem (Machine.R_COM) _ Logic.eq_refl) as
                         [v [v' [wf1 [wf2 wf3]]]].
                       rewrite <- C_next_e1 in wf1.
                       rewrite wf1 in Hload; inversion Hload; subst; clear Hload.
                       simpl in wf2. by [].
                     - intros vcom Hload eq_addr_set Cb eq_addr; subst.
                       apply In_in in H0; apply ComponentMemory.load_block_load in H0.
                       destruct H0 as [ptro [i compMem_bid_i]].
                       assert (Memory.load mem1 (Permission.data, cid, bid, i) =
                                 Some (Ptr (Permission.data, Cb, 0, ptro))) as Hload'.
                       { Local Transparent Memory.load.
                         unfold Memory.load; simpl; rewrite H compMem_bid_i.
                         reflexivity. }
                       eapply wfmem in wf_mem; last reflexivity.
                       destruct wf_mem as [wf_regs [post1 post2]].
                       specialize (IHReachable _ Hload Logic.eq_refl cid).
                       destruct bid; first contradiction.
                       rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem1) in Hload';
                         last (unfold Block.local; congruence).
                       rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem) in Hload';
                         last (unfold Block.local; congruence).
                       destruct (cid == C) eqn:eqC;
                         move: eqC => /eqP eqC; subst.
                       + specialize (post1 _ C_b C_next_e1).
                         destruct post1 as [_ [_ post1]].
                         apply steadysnap_shift in post1.
                         assert (not_local: S bid <> Block.local) by (unfold Block.local; congruence).
                         specialize (post1 (S bid) not_local).
                         destruct post1 as [[cid' bid'] [G1 [G2 G3]]].
                         specialize (G2 _ _ Hload') as [v' [_ renames]].
                         simpl in renames. discriminate.
                       + rewrite C_next_e1 in eqC.
                         assert (Cid_b: component_buffer cid).
                         { eapply load_in_intf in Hload'; eauto. }
                         specialize (post2 _ Cid_b eqC) as [post2 | post2].
                         * destruct post2 as [_ [_ post2]].
                           apply steadysnap_shift in post2.
                           assert (not_local: S bid <> Block.local) by (unfold Block.local; congruence).
                           specialize (post2 (S bid) not_local).
                           destruct post2 as [[cid' bid'] [G1 [G2 G3]]].
                           specialize (G2 _ _ Hload') as [v' [_ renames]].
                           simpl in renames. discriminate.
                         * destruct post2 as [_ [_ [[? ?] _]]].
                           destruct H2 as [src_compMem [mem0_cid nextblock]].
                           unfold Memory.load in Hload'.
                           rewrite /= mem0_cid in Hload'.
                           apply ComponentMemory.load_next_block in Hload'.
                           rewrite nextblock in Hload'.
                           unfold LOCALBUF_blockid in Hload'.
                           by []. }
                   { find_rcons_rcons. simpl in H2.
                     (*
  Hshift : traces_shift_each_other_option all_zeros_shift (uniform_shift 1)
             (project_non_inform (prefix0 ++ [:: e1])) (project_non_inform prefix_inform)
                      *)
                     inversion Hshift; subst.
                     clear -wf_mem Hmem Hmem1 wf_int_pref' H0 H H2 C_next_e1 C_b load_in_intf.
                     rename H2 into H1.
                     remember (Cb, 0) as addr. setoid_rewrite <- Heqaddr in H1.
                     remember (fset1 addr') as addr_set.
                     generalize dependent Cb. generalize dependent addr'.
                     induction H1.
                     - intros vcom shared eq_addr_set Cb eq_addr; subst.
                       destruct vcom as [].
                       simpl in H0. rewrite in_fset1 in H0.
                       move: H0 => /eqP H0; inversion H0; subst; clear H0.
                       setoid_rewrite cats1 in H.
                       inversion H.
                       + rewrite -H2 in shared; inversion shared.
                         * now destruct t.
                         * now destruct t.
                       + rewrite H0 in H3. rewrite H1 in H4.
                         apply H4 in shared.
                         destruct shared as [[? ?] [? [? ?]]].
                         clear -H10.
                         rewrite /all_zeros_shift /uniform_shift in H10.
                         rewrite /sigma_shifting_wrap_bid_in_addr /sigma_shifting_lefttoright_addr_bid in H10.
                         rewrite /sigma_shifting_lefttoright_option in H10.
                         destruct i1; simpl in H10;
                           rewrite ssrnat.subn0 ssrnat.addn1 in H10; congruence.
                     - intros vcom shared eq_addr_set Cb eq_addr; subst.
                       apply In_in in H2; apply ComponentMemory.load_block_load in H2.
                       destruct H2 as [ptro [i compMem_bid_i]].
                       assert (Memory.load mem1 (Permission.data, cid, bid, i) =
                                 Some (Ptr (Permission.data, Cb, 0, ptro))) as Hload'.
                       { Local Transparent Memory.load.
                         unfold Memory.load; simpl; rewrite H0 compMem_bid_i.
                         reflexivity.
                         Local Opaque Memory.load.
                       }
                       specialize (IHReachable _ shared Logic.eq_refl cid).
                       destruct bid; first contradiction.
                       rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem1) in Hload';
                         last (unfold Block.local; congruence).
                       rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem) in Hload';
                         last (unfold Block.local; congruence).
                       eapply wfmem in wf_mem; last reflexivity.
                       destruct wf_mem as [wf_regs [post1 post2]].
                       destruct (cid == C) eqn:eqC;
                         move: eqC => /eqP eqC; subst.
                       + specialize (post1 _ C_b C_next_e1).
                         destruct post1 as [_ [_ post1]].
                         apply steadysnap_shift in post1.
                         assert (not_local: S bid <> Block.local) by (unfold Block.local; congruence).
                         specialize (post1 (S bid) not_local).
                         destruct post1 as [[cid' bid'] [G1 [G2 G3]]].
                         specialize (G2 _ _ Hload') as [v' [_ renames]].
                         simpl in renames. discriminate.
                       + rewrite C_next_e1 in eqC.
                         assert (Cid_b: component_buffer cid).
                         { eapply load_in_intf in Hload'; eauto. }
                         specialize (post2 _ Cid_b eqC) as [post2 | post2].
                         * destruct post2 as [_ [_ post2]].
                           apply steadysnap_shift in post2.
                           assert (not_local: S bid <> Block.local) by (unfold Block.local; congruence).
                           specialize (post2 (S bid) not_local).
                           destruct post2 as [[cid' bid'] [G1 [G2 G3]]].
                           specialize (G2 _ _ Hload') as [v' [_ renames]].
                           simpl in renames. discriminate.
                         * destruct post2 as [_ [_ [[? ?] _]]].
                           destruct H3 as [src_compMem [mem0_cid nextblock]].
                           Local Transparent Memory.load.
                           unfold Memory.load in Hload'.
                           Local Opaque Memory.load.
                           rewrite /= mem0_cid in Hload'.
                           apply ComponentMemory.load_next_block in Hload'.
                           rewrite nextblock in Hload'.
                           unfold LOCALBUF_blockid in Hload'.
                           by []. }
                ++
                  (* Use [addr_shared_so_far_inv_2] that is not yet stated *)
                  rename Hshared into Hshared'.
                  assert (Hshared: addr_shared_so_far (Cb, b)
                                                      (rcons (project_non_inform prefix) (ERet (cur_comp s) ret_val mem' C'))).
                  { inversion wf_cs' as [? ? ? ? ? ? ? ? ? ? ? ? ? ? wf_mem8 ?].
                    subst.
                    eapply wfmem in wf_mem8 as [wf_regs [wf_mem8 wf_mem8']];
                      last reflexivity.
                    eapply addr_shared_so_far_inv_2 with (mem := mem0); eauto.
                    -- intros. by simplify_memory'.
                    -- simpl.
                       unfold all_zeros_shift, uniform_shift.
                       destruct (wf_regs Machine.R_COM _ Logic.eq_refl) as [vcom' [newarg' [G1 [G2 G3]]]].
                       simpl in *.
                       assert (vcom' = vcom).
                       { rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem8) in G1; last (unfold EXTCALL_offset; congruence).
                         rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem7) in G1; last congruence.
                         rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem6) in G1; last congruence.
                         rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem5) in G1; last congruence.
                         rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem4) in G1; last congruence.
                         rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem3) in G1; last congruence.
                         rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem2) in G1; last congruence.
                         rewrite (Memory.load_after_store_eq _ _ _ _ Hmem1') in G1; congruence. } subst vcom'.
                       assert (newarg' = ret_val).
                       { apply ipref_evsteps in wf_int_pref'.
                         rewrite cats1 in wf_int_pref'.
                         inversion wf_int_pref'. now destruct prefix0.
                         destruct prefix0. simpl in *. congruence.
                         now destruct prefix0.
                         find_rcons_rcons. rewrite cats1 in H7.
                         find_rcons_rcons. inversion H1; subst; eauto.
                       } subst.
                       auto.
                    -- eapply wfmem in wf_mem; last reflexivity.
                       destruct wf_mem as [_ [wf_mem _]].
                       intros; subst; simpl in *.
                       unfold postcondition_steady_state, postcondition_event_snapshot_steadystate in wf_mem.
                       specialize (wf_mem _ C_b C_next_e1) as [_ [_ [G _]]].
                       intros [| b'] not_local; first (unfold Block.local in not_local; congruence).
                       specialize (G _ not_local). destruct G as [addr [G1 [G2 G3]]].
                       eexists; split; last split; eauto.
                       ++ intros offset v Hload.
                          specialize (G2 _ _ Hload) as [v' [Hload' Hren]].
                          inversion wf_int_pref' as [U1 U2].
                          rewrite !cats1 in U1.
                          inversion U1.
                          ** now destruct prefix0.
                          ** now destruct prefix0 as [| ? []].
                          ** find_rcons_rcons. find_rcons_rcons.
                             inversion H6; subst; clear H6. eauto.
                       ++ intros offset v Hload.
                          inversion wf_int_pref' as [U1 U2].
                          rewrite !cats1 in U1.
                          inversion U1.
                          ** now destruct prefix0.
                          ** now destruct prefix0 as [| ? []].
                          ** find_rcons_rcons. find_rcons_rcons.
                             inversion H6; subst; clear H6. eauto.
                    -- eapply wfmem in wf_mem; last reflexivity.
                       destruct wf_mem as [_ [wf_mem1 wf_mem2]].
                       intros C0 C0_b.
                       destruct (C0 == next_comp_of_event e1) eqn:eC0;
                         move: eC0 => /eqP eC0; subst.
                       ++ left.
                          specialize (wf_mem1 _ C0_b Logic.eq_refl) as [_ [_ [G _]]].
                          { intros [| b'] not_local; first (unfold Block.local in not_local; congruence).
                            specialize (G _ not_local). destruct G as [addr [G1 [G2 G3]]].
                            eexists; split; last split; eauto.
                            ++ intros offset v Hload.
                               specialize (G2 _ _ Hload) as [v' [Hload' Hren]].
                               inversion wf_int_pref' as [U1 U2].
                               rewrite !cats1 in U1.
                               inversion U1.
                               ** now destruct prefix0.
                               ** now destruct prefix0 as [| ? []].
                               ** find_rcons_rcons. find_rcons_rcons.
                                  inversion H1; subst; clear H1. eauto.
                            ++ intros offset v Hload.
                               inversion wf_int_pref' as [U1 U2].
                               rewrite !cats1 in U1.
                               inversion U1.
                               ** now destruct prefix0.
                               ** now destruct prefix0 as [| ? []].
                               ** find_rcons_rcons. find_rcons_rcons.
                                  inversion H1; subst; clear H1. eauto. }
                       ++ specialize (wf_mem2 C0 C0_b eC0) as [wf_mem2 | wf_mem2].
                          ** left. destruct wf_mem2 as [_ [_ [G _]]].
                             { intros [| b'] not_local; first (unfold Block.local in not_local; congruence).
                               specialize (G _ not_local). destruct G as [addr [G1 [G2 G3]]].
                               eexists; split; last split; eauto.
                               ++ intros offset v Hload.
                                  specialize (G2 _ _ Hload) as [v' [Hload' Hren]].
                                  inversion wf_int_pref' as [U1 U2].
                                  rewrite !cats1 in U1.
                                  inversion U1.
                                  ** now destruct prefix0.
                                  ** now destruct prefix0 as [| ? []].
                                  ** find_rcons_rcons. find_rcons_rcons.
                                     inversion H1; subst; clear H1. eauto.
                               ++ intros offset v Hload.
                                  inversion wf_int_pref' as [U1 U2].
                                  rewrite !cats1 in U1.
                                  inversion U1.
                                  ** now destruct prefix0.
                                  ** now destruct prefix0 as [| ? []].
                                  ** find_rcons_rcons. find_rcons_rcons.
                                     inversion H1; subst; clear H1. eauto. }
                          ** right.
                             destruct wf_mem2 as [_ [_ [_ G]]].
                             now rewrite cats1.
                    -- intros C0 b0 C0_b not_eq not_shared shared.
                       assert (inv_mem: CSInvariants.CSInvariants.wf_mem_wrt_t_pc
                                          (mem_of_event_inform e1)
                                          (project_non_inform (prefix0 ++ [:: e1]))
                                          C).
                       { destruct p_gens_t_inform as [x star].
                         rewrite Et in star.
                         eapply star_app_inv in star as [x0 [star1 _]];
                           last eapply CS.CS.singleton_traces_inform.
                         eapply CSInvariants.CSInvariants.wf_state_wf_mem; eauto.
                         eapply CSInvariants.CSInvariants.is_prefix_wf_state_t; eauto.
                         eapply CS.CS.star_sem_inform_star_sem_non_inform. eauto.
                         erewrite CS.CS.starR_memory_of_event_inform; first by reflexivity.
                         eapply star_iff_starR. rewrite cats1 in star1. simpl in star1. eauto.
                         erewrite <- CS.CS.starR_next_comp_of_event_inform. eauto.
                         eapply star_iff_starR. rewrite cats1 in star1. simpl in star1. eauto. }
                       assert (inv_regs: CSInvariants.CSInvariants.wf_reg_wrt_t_pc
                                           (register_file_of_event_inform e1)
                                           (project_non_inform (prefix0 ++ [:: e1]))
                                           C).
                       { destruct p_gens_t_inform as [x star].
                         rewrite Et in star.
                         eapply star_app_inv in star as [x0 [star1 _]];
                           last eapply CS.CS.singleton_traces_inform.
                         eapply CSInvariants.CSInvariants.wf_state_wf_reg; eauto.
                         eapply CSInvariants.CSInvariants.is_prefix_wf_state_t; eauto.
                         eapply CS.CS.star_sem_inform_star_sem_non_inform. eauto.
                         erewrite CS.CS.starR_register_file_of_event_inform; first by reflexivity.
                         eapply star_iff_starR. rewrite cats1 in star1. simpl in star1. eauto.
                         erewrite <- CS.CS.starR_next_comp_of_event_inform. eauto.
                         eapply star_iff_starR. rewrite cats1 in star1. simpl in star1. eauto. }
                       clear -inv_mem inv_regs shared not_shared not_eq wf_int_pref'.
                       inversion shared; subst; clear shared.
                       ++ find_rcons_rcons. simpl in H1.
                          remember (C0, b0) as addr.
                          rewrite -Heqaddr in H1.
                          remember (addr_of_value ret_val) as addr_set.
                          generalize dependent b0. generalize dependent C0. generalize dependent ret_val.
                          induction H1.
                          ** intros new_arg wf_int_pref' eq_addr_set C0 C0_cur b0 eq_addr; subst.
                             simpl in H. destruct new_arg as [| [[[[]]]] |]; try discriminate.
                             simpl in H. rewrite in_fset1 in H.
                             move: H => /eqP H. inversion H; subst; clear H.
                             unfold CSInvariants.CSInvariants.wf_reg_wrt_t_pc in inv_regs.
                             inversion wf_int_pref' as [U1 _].
                             rewrite !cats1 in U1.
                             inversion U1.
                             --- now destruct prefix0.
                             --- now destruct prefix0 as [| ? []].
                             --- find_rcons_rcons. find_rcons_rcons.
                                 inversion H1; subst; clear H1. simpl in *.
                                 specialize (inv_regs _ _ H9 Logic.eq_refl).
                                 inversion inv_regs; subst; clear inv_regs.
                                 +++ unfold C in C0_cur. contradiction.
                                 +++ contradiction.
                          ** intros new_arg wf_int_pref' eq_addr_set C0 C0_cur b0 eq_addr; subst.
                             apply In_in in H0.
                             apply ComponentMemory.load_block_load in H0 as [? [i Hload']].
                             assert (Hload: Memory.load mem' (Permission.data, cid, bid, i) =
                                              Some (Ptr (Permission.data, C0, b0, x))).
                             { Local Transparent Memory.load.
                               unfold Memory.load. simpl. rewrite H. assumption.
                               Local Opaque Memory.load. }
                             inversion wf_int_pref' as [U1 _].
                             rewrite !cats1 in U1.
                             inversion U1.
                             --- now destruct prefix0.
                             --- now destruct prefix0 as [| ? []].
                             --- find_rcons_rcons. find_rcons_rcons.
                                 inversion H3; subst; clear H3. simpl in *.
                                 specialize (inv_mem _ _ Hload Logic.eq_refl).
                                 inversion inv_mem; subst; clear inv_mem.
                                 (* CSInvariants.CSInvariants.wf_load *)
                                 +++ simpl in *. subst.
                                     specialize (IHReachable H3 _ wf_int_pref').
                                     eapply IHReachable; eauto.
                                 +++ simpl in *. subst. contradiction.
                                 +++ simpl in *. subst. contradiction.

                       ++ find_rcons_rcons. simpl in H2.
                          remember (C0, b0) as addr.
                          rewrite -Heqaddr in H2.
                          remember (fset1 addr') as addr_set.
                          generalize dependent b0. generalize dependent C0. generalize dependent addr'.
                          induction H2.
                          ** intros addr' shared eq_addr_set C0 C0_cur b0 eq_addr; subst.
                             simpl in H. destruct addr' as [cid bid].
                             simpl in H. rewrite in_fset1 in H.
                             move: H => /eqP H. inversion H; subst; clear H.
                             contradiction.
                          ** intros addr' shared eq_addr_set C0 C0_cur b0 eq_addr; subst.
                             apply In_in in H0.
                             apply ComponentMemory.load_block_load in H0 as [? [i Hload']].
                             assert (Hload: Memory.load mem' (Permission.data, cid, bid, i) =
                                              Some (Ptr (Permission.data, C0, b0, x))).
                             { Local Transparent Memory.load.
                               unfold Memory.load. simpl. rewrite H. assumption.
                               Local Opaque Memory.load. }
                             inversion wf_int_pref' as [U1 _].
                             rewrite !cats1 in U1.
                             inversion U1.
                             --- now destruct prefix0.
                             --- now destruct prefix0 as [| ? []].
                             --- find_rcons_rcons. find_rcons_rcons.
                                 inversion H3; subst; clear H3. simpl in *.
                                 specialize (inv_mem _ _ Hload Logic.eq_refl).
                                 inversion inv_mem; subst; clear inv_mem.
                                 (* CSInvariants.CSInvariants.wf_load *)
                                 +++ simpl in *. subst.
                                     eapply IHReachable; eauto.
                                 +++ simpl in *. subst. contradiction.
                                 +++ simpl in *. subst. contradiction.
                    -- intros C0 b0 o v Hload. unfold component_buffer.
                       (* Use p_interm and p_gens_t. *)
                       (* and (CS.CS.comes_from_initial_state_mem_domm _ intf). *)


                       pose proof (star_trans Star0 Star1 Logic.eq_refl) as G.
                       eapply CS.comes_from_initial_state_mem_domm in G; simpl in *; eauto.
                       ++ rewrite -G.
                          rewrite (Memory.domm_store _ _ _ _ Hmem1).
                          apply /dommP.
                          Local Transparent Memory.load.
                          unfold Memory.load in Hload. simpl in Hload.
                          destruct (mem1 C0) eqn:mem1_C0; last discriminate. by eauto.
                          Local Opaque Memory.load.
                       ++ {
                           eapply well_formed_events_well_formed_program
                           in wf_events as [theprog [Hrewr ?]]; eauto.
                           + erewrite Hprog_of_trace in Hrewr. inversion Hrewr.
                             by subst theprog.
                           + by eapply domm_t_procs_exported_procedures_of_trace.
                         }
                       ++ by apply closed_program_of_trace in Hprog_of_trace.
                       ++ by simpl.

                    -- intros ptr ? ? ?. simpl.
                       destruct (Pointer.eq ptr
                                            (Permission.data, C, Block.local, EXTCALL_offset)) eqn:eq_ptr;
                         move: eq_ptr => /Pointer.eqP eq_ptr; subst;
                                         [erewrite Memory.load_after_store_eq; eauto; by [] |
                                           erewrite Memory.load_after_store_neq; eauto].
                       destruct (Pointer.eq ptr
                                            (Permission.data, C, Block.local, 0%Z)) eqn:eq_ptr';
                         move: eq_ptr' => /Pointer.eqP eq_ptr'; subst;
                                          [erewrite Memory.load_after_store_eq; eauto; by [] |
                                            erewrite Memory.load_after_store_neq; eauto].
                       eapply wfmem_no_private_ptr; eauto.
                    -- eapply traces_rename_each_other_option_symmetric. reflexivity.
                       inversion Hshift; eauto.
                  } clear Hshared'.
                  exists (Cb, b). split; last split.
                  ** rewrite /all_zeros_shift /uniform_shift
                             /sigma_shifting_wrap_bid_in_addr
                             /sigma_shifting_lefttoright_addr_bid /=.
                     now rewrite ssrnat.subn0 ssrnat.addn1.
                  **
                    {
                      rewrite /all_zeros_shift /uniform_shift
                              /event_renames_event_at_shared_addr //=.
                      destruct cs'. simpl in mem_cs'; subst s_memory.
                      inversion wf_cs' as [? ? ? ? ? ? ? ? ? ? ? ? ? ? wf_mem8 ?].
                      subst C0 stk0 mem9 s_cont s_expr s_arg k exp s_component.
                      eapply wfmem in wf_mem8 as [wf_regs [wf_mem8 wf_mem8']];
                        last reflexivity.
                      simpl in wf_regs, wf_mem8, wf_mem8'.
                      unfold postcondition_steady_state in wf_mem8.
                      unfold postcondition_event_snapshot_steadystate in wf_mem8.
                      case Cb_C: (Cb == C'); move: Cb_C => /eqP Cb_C; [subst Cb |].
                      * specialize (wf_mem8 _ C'_b Logic.eq_refl) as [_ [_ [Hshift1 _]]].
                        unfold well_formed_memory_snapshot_steadystate_shift in Hshift1.
                        unfold memory_shifts_memory_at_shared_addr in Hshift1.
                        unfold all_zeros_shift, uniform_shift in Hshift1.
                        simpl in Hshift1.
                        specialize (Hshift1 (S b)).
                        unfold memory_renames_memory_at_shared_addr in *.
                        eexists (C', S b).
                        split; [| split].
                        -- rewrite /sigma_shifting_wrap_bid_in_addr. simpl.
                           by rewrite ssrnat.subn0 ssrnat.addn1.
                        -- intros off v Hload; simpl in *.
                           destruct Hshift1 as [addr' [Hshift1 [Hshift2 Hshift3]]];
                             first easy.
                           rewrite /sigma_shifting_wrap_bid_in_addr //= in Hshift1.
                           rewrite ssrnat.subn1 ssrnat.addn0 in Hshift1.
                           inversion Hshift1; subst addr'.
                           simpl in Hshift3.
                           specialize (Hshift3 _ _ Hload) as [? [? ?]].
                           eexists; split.
                           ++ repeat match goal with
                                     | Hload: Memory.load ?mem' ?ptr' = Some ?v',
                                         Hstore: Memory.store ?mem ?ptr ?v = Some ?mem' |- _ =>
                                         erewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hstore) in Hload
                                     end.
                              by simplify_memory.
                           ++ destruct x; simpl in *; try by inversion H0; subst v.
                              destruct t0 as [[[[|] ?] ?] ?]; simpl in *.
                              by inversion H0.
                              destruct i0; inversion H0; subst v.
                              by rewrite //= ssrnat.subn1 ssrnat.addn0 ssrnat.subn0 ssrnat.addn1.
                        -- intros off v Hload; simpl in *.
                           destruct Hshift1 as [addr' [Hshift1 [Hshift2 Hshift3]]];
                             first easy.
                           rewrite /sigma_shifting_wrap_bid_in_addr //= in Hshift1.
                           rewrite ssrnat.subn1 ssrnat.addn0 in Hshift1.
                           inversion Hshift1; subst addr'.
                           simpl in Hshift2.
                           assert (Hload': Memory.load mem8 (Permission.data, C', S b, off) = Some v)
                             by simplify_memory.
                           specialize (Hshift2 _ _ Hload') as [? [? ?]].
                           eexists; split.
                           ++ eassumption.
                           ++ destruct v; simpl in *; try by inversion H0; subst x.
                              destruct t0 as [[[[|] ?] ?] ?]; simpl in *.
                              by inversion H0.
                              destruct i0; inversion H0; subst x.
                              by rewrite //= ssrnat.subn1 ssrnat.addn0 ssrnat.subn0 ssrnat.addn1.
                      * (* Prove good_trace something. Get from Hshared that there's a
                         * load and [1 <= b]. Now we can get a contradiction to
                         * [postcondition_uninitialized] *)
                        (* *)
                        exists (Cb, S b).
                        split.
                        -- rewrite /all_zeros_shift /uniform_shift //=.
                           rewrite /sigma_shifting_wrap_bid_in_addr //=.
                           by rewrite ssrnat.subn0 ssrnat.addn1.
                        --

                          assert (Hwf_p: Source.well_formed_program p).
                          {
                            eapply well_formed_events_well_formed_program
                              in wf_events as [theprog [Hrewr ?]]; eauto.
                            + erewrite Hprog_of_trace in Hrewr. inversion Hrewr.
                              by subst theprog.
                            + by eapply domm_t_procs_exported_procedures_of_trace.
                          }
                          assert (Hclosed_p: Source.closed_program p).
                          {
                            by eapply closed_program_of_trace; eauto.
                          }

                          assert (Star_init_ret:
                                   Star
                                     (CS.sem p)
                                     (CS.initial_machine_state p)
                                     (prefix' ++ [:: ERet C vcom mem1 C'])
                                     [CState cur_comp s',
                                       s_stack,
                                       mem8,
                                       Kstop,
                                       expr_of_trace
                                         (cur_comp s') P0
                                         (comp_subtrace (cur_comp s') t),
                                       arg0]
                                 ).
                          {
                            eapply star_trans.
                            - eapply Star0.
                            - eapply star_trans; eauto.
                              eapply star_trans; eauto.
                            - reflexivity.
                          }
                          split; intros ? ? Hload.
                          ++ simpl in *.
                             assert (HCb: component_buffer Cb).
                             {
                               (** This essentially follows IF we knew that the
                          intermediate trace came from an intermediate execution.
                          Then, we can possibly use a lemma in CSInvariants? *)

                               unfold component_buffer.
                               replace intf with (Machine.Intermediate.prog_interface p_interm).
                               destruct p_gens_t as [? G].
                               rewrite Et project_non_inform_append in G.
                               simpl in G. unfold Eapp in G.
                               replace ((ERet (cur_comp s) ret_val mem' C' :: project_non_inform suffix)) with ([:: ERet (cur_comp s) ret_val mem' C'] ++ project_non_inform suffix) in G; last reflexivity.
                               setoid_rewrite app_assoc in G.
                               apply star_app_inv in G as [? [G _]].
                               setoid_rewrite cats1 in G.
                               eapply CSInvariants.CSInvariants.load_Some_component_buffer with
                                 (ptr := (Permission.data, Cb, b, offset))
                                 (e := (ERet (cur_comp s) ret_val mem' C')); eauto.
                               apply CS.CS.singleton_traces_non_inform.
                             }
                             specialize (wf_mem8' _ HCb Cb_C) as
                               [[? [? [? ?]]] | [? [? [[[compMem [? HcompMem]] ?] Hnot_shared]]] ].
                             ** assert (Hnoteq: S b <> Block.local).
                                { by unfold Block.local. }
                                specialize (steadysnap_shift0 _ Hnoteq)
                                  as [[C_ b_] [Hb_ [mem8_mem' mem'_mem8]]].
                                rewrite shift_S_Some in Hb_.
                                inversion Hb_; subst C_ b_; clear Hb_.
                                simpl in *.
                                specialize (mem'_mem8 _ _ Hload) as [v' [Hloadv' Hv']].
                                exists v'. split.
                                ---
                                  simplify_memory_in_assm.
                                --- specialize (shift_value_option_symmetry
                                                  (fun=> 1) (fun=> 0)) as Lem.
                                    unfold shift_value_option,
                                      sigma_shifting_wrap_bid_in_addr,
                                      sigma_shifting_lefttoright_addr_bid,
                                      rename_addr_option in *.
                                    by eapply Lem.
                             ** simpl in *. destruct HcompMem as [HcompMem [? [Hnext ?]]].
                                (** Intuitively, there should be a contradiction. *)
                                (** In particular, ** is the case where Cb is not *)
                                (** initialized. What we know about Cb is that it *)
                                (** shared an address and that this address also was *)
                                (** loaded from memory (Hload). *)
                                specialize (Hnot_shared b).
                                rewrite -!cats1 project_non_inform_append /= in Hnot_shared.
                                setoid_rewrite cats1 in Hnot_shared.
                                apply Hnot_shared in Hshared.
                                contradiction.
                          ++ simpl in *.
                             assert (Hload': Memory.load
                                               mem8
                                               (Permission.data, Cb, S b, offset) = Some v').
                             {
                               by simplify_memory.
                             }
                             (** Need to know component_buffer Cb. *)
                             (** Intuitively, we should know it from Hload *)
                             (** Knowing it from Hload should be a source "CSInvariant". *)

                             assert (HCb: component_buffer Cb).
                             {
                               unfold component_buffer.
                               replace intf with (Machine.Intermediate.prog_interface p_interm).

                               specialize (@CS.CS.load_component_prog_interface_addr
                                             _ Hwf_p Hclosed_p _ _ _
                                             (Permission.data, Cb, S b, offset) v'
                                             Logic.eq_refl Star_init_ret
                                          ) as G'.
                               simpl in *. rewrite p_interm_intf.
                               subst p. simpl in *.
                               eapply G'; eauto.
                             }


                             specialize (wf_mem8' _ HCb Cb_C) as
                               [[? [? [? ?]]] | [? [? [[[compMem [? HcompMem]] ?] Hnot_shared]]] ].
                             ** assert (Hnoteq: S b <> Block.local).
                                { by unfold Block.local. }
                                specialize (steadysnap_shift0 _ Hnoteq)
                                  as [[C_ b_] [Hb_ [mem8_mem' mem'_mem8]]].
                                rewrite shift_S_Some in Hb_.
                                inversion Hb_; subst C_ b_; clear Hb_.
                                simpl in *.
                                specialize (mem8_mem' _ _ Hload') as [v'' [Hloadv' Hv']].
                                exists v''. split.
                                --- assumption.
                                --- specialize (shift_value_option_symmetry
                                                  (fun=> 1) (fun=> 0)) as Lem.
                                    unfold shift_value_option,
                                      sigma_shifting_wrap_bid_in_addr,
                                      sigma_shifting_lefttoright_addr_bid,
                                      rename_addr_option in *.
                                    by eapply Lem.
                             ** (** Hshared =/= Hnot_shared*)
                               rewrite -cats1 project_non_inform_append in Hnot_shared.
                               setoid_rewrite cats1 in Hnot_shared.
                               by apply Hnot_shared in Hshared.
                    }
                  ** eauto.
              - easy.
              - rewrite /all_zeros_shift /uniform_shift
                        /sigma_shifting_wrap_bid_in_addr
                        /sigma_shifting_lefttoright_addr_bid /=.
                destruct ret_val.
                + rewrite //=.
                  destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                  inversion wf_int_pref'.
                  * now destruct prefix.
                  * destruct prefix as [|? []]; try discriminate.
                    now destruct prefix0.
                  * rewrite cats1 in H. apply rcons_inj in H. inversion H; subst; clear H.
                    rewrite cats1 in H3. apply rcons_inj in H3. inversion H3; subst; clear H3.
                    inversion H1; subst; clear H1. simpl in *.
                    pose proof (wfmem wf_mem Logic.eq_refl) as [Hregs [Hnextcomp Hnotnextcomp]].
                    specialize (Hregs Machine.R_COM _ Logic.eq_refl) as [v [v' [H1 H2]]].
                    simpl in *.
                    rewrite -C_next_e1 in H1.
                    rewrite H1 in Hcom. inversion Hcom. subst. destruct H2 as [H2 H3].
                    rewrite H3 in H9; subst. rewrite H9 in H2.
                    destruct vcom; try discriminate. simpl in H2. eauto. simpl in H2.
                    destruct t0 as [[[]]]. destruct (Permission.eqb i Permission.data);
                                             try discriminate.
                    rewrite /all_zeros_shift /uniform_shift in H2.
                    rewrite /rename_addr_option //= in H2.
                    rewrite /sigma_shifting_wrap_bid_in_addr
                            /sigma_shifting_lefttoright_addr_bid
                            /sigma_shifting_lefttoright_option in H2.
                    destruct i1; simpl in H2. discriminate.
                    inversion H2.
                + destruct t0 as [[[? ?] ?] ?].
                  destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                  inversion wf_int_pref'.
                  * now destruct prefix.
                  * destruct prefix as [|? []]; try discriminate.
                    now destruct prefix0.
                  * rewrite cats1 in H. apply rcons_inj in H. inversion H; subst; clear H.
                    rewrite cats1 in H3. apply rcons_inj in H3. inversion H3; subst; clear H3.
                    inversion H1; subst; clear H1. simpl in *.
                    pose proof (wfmem wf_mem Logic.eq_refl) as [Hregs [Hnextcomp Hnotnextcomp]].
                    specialize (Hregs Machine.R_COM _ Logic.eq_refl) as [v [v' [H1 H2]]].
                    simpl in *.
                    rewrite -C_next_e1 in H1.
                    rewrite H1 in Hcom. inversion Hcom. subst; clear Hcom.
                    destruct H2 as [H2 H3].
                    rewrite H3 in H9; subst. rewrite H9 in H2.
                    destruct vcom; try discriminate. simpl in H2.
                    destruct t0 as [[[]]].
                    (* destruct (Permission.eqb i2 Permission.data); *)
                    (*   try discriminate. *)
                    rewrite /all_zeros_shift /uniform_shift in H2.
                    rewrite /rename_addr_option //= in H2.
                    rewrite /sigma_shifting_wrap_bid_in_addr
                            /sigma_shifting_lefttoright_addr_bid
                            /sigma_shifting_lefttoright_option in H2.
                    destruct (Permission.eqb i2 Permission.data) eqn:perm1;
                      destruct (Permission.eqb i Permission.data) eqn:perm2; simpl in *.
                    -- destruct i4; simpl in H2; try discriminate.
                       inversion H2; subst; clear H2.
                       rewrite ssrnat.subn1 //= ssrnat.addn0 ssrnat.subn0 ssrnat.addn1 //=.
                    -- destruct i4; simpl in H2; try discriminate.
                       inversion H2; subst; clear H2. congruence.
                    -- destruct i4; simpl in H2; try discriminate;
                         inversion H2; subst; clear H2; congruence.
                    -- destruct i4; simpl in H2; try discriminate;
                         inversion H2; subst; clear H2; reflexivity.
                + rewrite //=.
                  destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                  inversion wf_int_pref'.
                  * now destruct prefix.
                  * destruct prefix as [|? []]; try discriminate.
                    now destruct prefix0.
                  * rewrite cats1 in H. apply rcons_inj in H. inversion H; subst; clear H.
                    rewrite cats1 in H3. apply rcons_inj in H3. inversion H3; subst; clear H3.
                    inversion H1; subst; clear H1. simpl in *.
                    pose proof (wfmem wf_mem Logic.eq_refl) as [Hregs [Hnextcomp Hnotnextcomp]].
                    specialize (Hregs Machine.R_COM _ Logic.eq_refl) as [v [v' [H1 H2]]].
                    simpl in *.
                    rewrite -C_next_e1 in H1.
                    rewrite H1 in Hcom. inversion Hcom. subst. destruct H2 as [H2 H3].
                    rewrite H3 in H9; subst. rewrite H9 in H2.
                    destruct vcom; try discriminate. simpl in H2. eauto. simpl in H2.
                    destruct t0 as [[[]]]. destruct (Permission.eqb i Permission.data);
                                             try discriminate.
                    rewrite /all_zeros_shift /uniform_shift in H2.
                    rewrite /rename_addr_option //= in H2.
                    rewrite /sigma_shifting_wrap_bid_in_addr
                            /sigma_shifting_lefttoright_addr_bid
                            /sigma_shifting_lefttoright_option in H2.
                    destruct i1; simpl in H2. discriminate.
                    inversion H2. auto.
              - constructor.
                intros [Cb b] Hshared.
                constructor.
              - constructor.
                intros [Cb b] Hshared.
                (* rewrite /right_addr_good_for_shifting. *)
                (* rewrite /right_block_id_good_for_shifting /uniform_shift. *)
                inversion Hshared; subst; clear Hshared.
                + find_rcons_rcons. simpl in *.
                  remember (Cb, b) as addr. generalize dependent b. generalize dependent Cb.
                  inversion H1; intros; subst.
                  * destruct vcom as [| [[[[]]]] |]; try by rewrite in_fset0 in H.
                    rewrite in_fset1 in H. move: H => /eqP H; inversion H; subst.
                    pose proof (wfmem wf_mem Logic.eq_refl) as [steady_C1 [? ?]].
                    specialize (steady_C1 Machine.R_COM _ Logic.eq_refl) as [vcom1 [vcom2 [G1 [G2 _]]]].
                    simpl in G1. unfold C in C_next_e1; rewrite C_next_e1 in Hcom. rewrite G1 in Hcom.
                    inversion Hcom; subst.
                    rewrite /all_zeros_shift /uniform_shift //= in G2.
                    destruct i0; try discriminate. constructor.
                  * apply In_in in H2. apply ComponentMemory.load_block_load in H2 as [off' [off Hload]].
                    assert (load: Memory.load mem1 (Permission.data, cid, bid, off) =
                                    Some (Ptr (Permission.data, Cb, b, off'))).
                    { Local Transparent Memory.load.
                      unfold Memory.load. simpl.
                      rewrite H0. assumption.
                      Local Opaque Memory.load.
                    }
                    rewrite (Memory.load_after_store _ _ _ _ _ Hmem1) in load.
                    move: load; case: ifP => //= _ load.
                    rewrite (Memory.load_after_store _ _ _ _ _ Hmem) in load.
                    move: load; case: ifP => //= _ load.
                    eapply wfmem_no_private_ptr in load; eauto.
                    now destruct b.
                + find_rcons_rcons.
                  inversion H2; intros; subst.
                  * inversion Hshift; subst; clear Hshift.
                    inversion H1; subst; clear H1. rewrite <- H5 in H0; inversion H0; try now destruct t0.
                    rewrite H4 in H12.
                    inversion H12; subst; clear H12.
                    eapply H1 in H0. by rewrite in_fset1 in H; move: H => /eqP ->.
                  * apply In_in in H3. apply ComponentMemory.load_block_load in H3 as [off' [off Hload]].
                    assert (load: Memory.load mem1 (Permission.data, cid, bid, off) =
                                    Some (Ptr (Permission.data, Cb, b, off'))).
                    { Local Transparent Memory.load.
                      unfold Memory.load. simpl.
                      rewrite H1. assumption.
                      Local Opaque Memory.load.
                    }
                    rewrite (Memory.load_after_store _ _ _ _ _ Hmem1) in load.
                    move: load; case: ifP => //= _ load.
                    rewrite (Memory.load_after_store _ _ _ _ _ Hmem) in load.
                    move: load; case: ifP => //= _ load.
                    eapply wfmem_no_private_ptr in load; eauto.
                    now destruct b.
            }

          (* NOTE: ... And there is a series of new events to consider. *)

          - (* EConst *)
            (* Gather a few recurrent assumptions at the top. *)
            exists (EConst C ptr v s0 t0).

            assert (prefix = [::] \/ exists prefix' e', prefix = prefix' ++ [:: e'])
              as [Hprefix | [prefix0 [e1 Hprefix01]]].
            {
              destruct prefix; first by auto.
              right. rewrite lastI -cats1. by eauto.
            }
            { (* Treat empty case separately. *)
              subst prefix. simpl in *.
              assert (Hmain : C = Component.main).
              { unfold C. rewrite Et /= in wb_trace.
                by move: wb_trace => /andP => [[]] => /eqP. }
              subst C. (* NOTE: Avoid substituting to stay close to the standard proof? *)

              destruct (wfmem_ini wf_mem Logic.eq_refl C_b)
                as [Hregs0 [_ Hmaincomp]].
              specialize (Hmaincomp Hmain)
                as [Hload0init [Hload0local Hsnapshot0]].
              destruct (postcondition_event_registers_load v Hregs0)
                as [v_reg_v [Hload0v _]].
              (* assert (Hload0v := Hregs0 (Ereg_to_reg v) _ Logic.eq_refl). *)
              (* rewrite reg_to_Ereg_to_reg in Hload0v. *)
              assert (Hload1v := Hload0v).
              erewrite <- Memory.load_after_store_neq in Hload1v;
                last exact Hmem;
                last (injection; now destruct v).
              set saved := match ptr with
                           | Ptr (Permission.data, C, b, o) =>
                               eval_binop Add (Ptr (Permission.data, C, LOCALBUF_blockid, 0%Z)) (Int o)
                           | _ => ptr
                           end.
              destruct (proj1 (Memory.store_some_load_some _ _ saved) (ex_intro _ _ Hload1v))
                as [mem2 Hstore2].
              destruct (Memory.alloc_after_load
                          _ _ _ _ _ _ (buffer_size Component.main)
                          (Memory.load_after_store_eq _ _ _ _ Hstore2))
                as [mem3 [bnew [Hnewblock Halloc3]]].
              assert (Hload3local := Hload0local).
              erewrite <- Memory.load_after_store_neq in Hload3local;
                last exact Hmem;
                last (injection; discriminate).
              erewrite <- Memory.load_after_store_neq in Hload3local;
                last exact Hstore2;
                last (injection; now destruct v).
              erewrite <- Memory.load_after_alloc in Hload3local;
                [ | exact Halloc3 | injection; congruence].
              destruct (proj1 (Memory.store_some_load_some _ _ (Ptr (Permission.data, Component.main, bnew, 0%Z))) (ex_intro _ _ Hload3local))
                as [mem4 Hstore4].
              assert (Hload0extcall := proj1 (wfmem_extcall_ini wf_mem Logic.eq_refl) _ C_b Hmain).

              (* NOTE: These sub-cases are fundamentally identical and easily refactored. *)
              destruct ptr as [n | ptr |];
                exists (StackState Component.main (callers s));
                eexists. (* evar (CS : state (CS.sem p)). exists CS. *)

              + (* EConst-Int *)
                split; [| split].
                { (** star steps *)
                  Local Transparent expr_of_const_val loc_of_reg.
                  take_steps;
                    first exact Hstore2.
                  take_steps; (* Do recursive call. *)
                    [eapply find_procedures_of_trace; eauto; by subst p|].
                  (* Done with the event. *)
                  take_steps; (* Process external call check. *)
                    first (simplify_memory'; exact Hload0init).
                  take_steps.
                  - unfold buffer_size.
                    destruct (prog_buffers Component.main) as [Cbuf |] eqn:HCbuf.
                    + assert (Hwf_buf := wf_buffers HCbuf).
                      destruct Cbuf as [sz | vs]; auto.
                      * simplify_memory; by destruct v.
                      * simplify_memory; by destruct v.
                    + simplify_memory; by destruct v.
                  (* - rewrite Nat2Z.id. exact Halloc3. *)
                  - take_steps.
                    (*   first exact Hstore4. *)
                    (* eapply star_trans with (t2 := E0); *)
                    (*   first exact Hstar_init; *)
                    (*   last reflexivity. *)
                    (* take_steps; *)
                    (*   first (simplify_memory'; exact Hload0extcall). *)
                    (* take_steps. *)
                    apply star_refl.
                }
                { (** well-formed state *)
                  econstructor; try reflexivity; try eassumption.
                  { destruct s. rewrite -Hmain. exact wb. }
                  { destruct wf_stk as [top [bot [Heq [Htop Hbot]]]]; subst stk.
                    eexists ({| CS.f_component := Component.main; CS.f_arg := arg; CS.f_cont := Kstop |} :: top).
                    exists bot. rewrite -Hmain. split; [| split]; [easy | easy |].
                    simpl.
                    elim: (callers s) bot Hbot {Star0 Star1}; trivial.
                    move=> a l IH bot [] H1 H2.
                    fold well_formed_callers in *.
                    split.
                    ++ simplify_memory.
                       destruct v; unfold INITFLAG_offset; simpl; try congruence.
                    (* destruct (a == ) eqn:eq; *)
                    (*   move: eq => /eqP eq; subst. *)
                    (* simplify_memory. *)
                    (* ** now destruct Postcond1. *)
                    (* ** rewrite -Hmem2'; last congruence. *)
                    (*    now simplify_memory. *)
                    ++ destruct H2 as [? [? [? [? [? [? [? H2]]]]]]].
                       eexists; eexists; eexists; eexists.
                       repeat split; eauto.
                  }
                  (* Reestablish memory well-formedness.
               TODO: Refactor, automate. *)
                  { (* destruct wf_mem as [wfmem_counter wfmem_meta wfmem]. *)
                    constructor.
                    - intros C_ Hcomp.
                      destruct (Nat.eqb_spec Component.main C_) as [Heq | Hneq].
                      + subst C_.
                        rewrite -Hmain. (* TODO: Rewrite Hmain earlier, avoid duplication *)
                        by simplify_memory'.
                      + simplify_memory'.
                        assert (Hload0 := wfmem_counter wf_mem Hcomp).
                        rewrite Hload0.
                        rewrite /counter_value /=.
                        move: Hneq => /eqP.
                        case: ifP;
                          last reflexivity.
                        move => /eqP => Hcontra => /eqP => Hneq.
                        rewrite Hcontra in Hneq. congruence.
                    - discriminate.
                    - intros pref ev Hprefix.
                      destruct pref as [| ? [ | ]]; try discriminate.
                      injection Hprefix as ?; subst ev.
                      split.
                      + intros C_ Hcomp Hnext.
                        destruct (Nat.eqb_spec Component.main C_) as [Heq | Hneq].
                        * subst C_.
                          simplify_memory'.
                          apply (proj1 (wfmem_extcall_ini wf_mem Logic.eq_refl) _ Hcomp).
                          congruence.
                        * subst C_. rewrite Hmain in Hneq. contradiction.
                      + intros C_ Hcomp Hnext.
                        destruct (Nat.eqb_spec Component.main C_) as [Heq | Hneq].
                        * subst C_. rewrite Hmain in Hnext. contradiction.
                        * simplify_memory'.
                          apply (proj2 (wfmem_extcall_ini wf_mem Logic.eq_refl) _ Hcomp).
                          intros ?; subst C_. contradiction.
                    - intros C_ reg Hcomp.
                      destruct (postcondition_event_registers_load reg Hregs0)
                        as [v_reg_reg [Hload0reg _]].
                      (* assert (Hload0reg := Hregs0 (Ereg_to_reg reg) _ Logic.eq_refl). *)
                      (* rewrite reg_to_Ereg_to_reg in Hload0reg. *)
                      destruct (Nat.eqb_spec Component.main C_) as [Heq | Hneq].
                      + subst C_.
                        rewrite -Hmain.
                        destruct (EregisterP reg v) as [Heq | Hneq].
                        * subst v.
                          eexists.
                          by simplify_memory'.
                        * eexists.
                          simplify_memory'.
                          exact Hload0reg.
                      + destruct (wfmem_ini wf_mem Logic.eq_refl Hcomp) as [Hregs0' _].
                        destruct (postcondition_event_registers_load reg Hregs0')
                          as [v_reg_reg' [Hload0reg' _]].
                        eexists.
                        (* assert (Hload0reg' := Hregs0' (Ereg_to_reg reg) _ Logic.eq_refl). *)
                        (* rewrite reg_to_Ereg_to_reg in Hload0reg'. *)
                        simplify_memory'. exact Hload0reg'.
                    - discriminate.
                    - intros pref ev Hprefix.
                      destruct pref as [| ? [ | ]]; try discriminate.
                      injection Hprefix as ?; subst ev.
                      split; [| split].
                      + {
                        intros reg off Hoffset.
                        destruct (wfmem_ini wf_mem Logic.eq_refl C_b) as [Hregs _].
                        destruct (EregisterP (reg_to_Ereg reg) v) as [Heq | Hneq].
                        - subst v off.
                          eexists. eexists.
                          split; [| split].
                          + by simplify_memory'.
                          + reflexivity.
                          + rename t0 into eregs.
                            destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                            inversion wf_int_pref' as [| eint Hstep Heint | prefint eint1 eint2 Hsteps Hstep Ht].
                            { subst eint.
                              inversion Hstep as [| | tmp1 tmp2 tmp3 tmp4 tmp5 tmp6 | | | | |];
                                subst tmp1 tmp2 tmp3 tmp4 tmp5 tmp6;
                                subst eregs;
                                rewrite Ereg_to_reg_to_Ereg Machine.Intermediate.Register.gss;
                                reflexivity.
                            }
                            { destruct prefint as [| ? []]; discriminate. }
                        - destruct (postcondition_event_registers_load (reg_to_Ereg reg) Hregs)
                          as [v_reg_reg [Hload0reg Hv_reg_reg]].
                          eexists. eexists.
                          split; [| split].
                          * subst off. simplify_memory.
                            -- injection. by destruct reg.
                            -- injection.
                               move=> /reg_offset_inj => ?; subst v;
                                                         contradiction.
                          * destruct Hv_reg_reg as [|]; subst v_reg_reg;
                              reflexivity.
                          * rename t0 into eregs.
                            destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                            inversion wf_int_pref' as [| eint Hstep Heint | prefint eint1 eint2 Hsteps Hstep Ht].
                            { subst eint.
                              inversion Hstep as [| | tmp1 tmp2 tmp3 tmp4 tmp5 tmp6 | | | | |];
                                subst tmp1 tmp2 tmp3 tmp4 tmp5 tmp6;
                                subst eregs;
                                rewrite Machine.Intermediate.Register.gso;
                                last (intros ?; subst reg; now destruct v).
                              destruct (Machine.registerP reg Machine.R_COM) as [| Hreg].
                              - subst reg.
                                rewrite (proj2 Hregs) in Hload0reg.
                                injection Hload0reg as ?; subst v_reg_reg.
                                now rewrite Machine.Intermediate.Register.gss.
                              - rewrite ((proj1 Hregs) _ _ Hreg Logic.eq_refl)
                                  in Hload0reg.
                                injection Hload0reg as ?; subst v_reg_reg.
                                rewrite Machine.Intermediate.Register.gso;
                                  last exact Hreg.
                                rewrite /Machine.Intermediate.Register.get
                                        Machine.Intermediate.Register.reg_in_domm_init_Undef; last (apply /dommP; exists Undef; now destruct reg).
                                by destruct reg.
                            }
                            { destruct prefint as [| ? []]; discriminate. }
                      }
                      + intros C' _ ?; subst C'. simpl. (* lookup *)
                        (* This is directly needed for the second sub-goal, but also
                     useful for the fourth one. *)
                        destruct (wfmem_ini wf_mem Logic.eq_refl C_b)
                          as [Hregs [_ Hmaincomp]].
                        specialize (Hmaincomp Hmain) as [Hinitflag [Hlocalbuf [Hshift0 Hblock0]]].
                        split; [| split; [| split]].
                        * by simplify_memory'.
                        * by simplify_memory'. (* Trivial due to work up front. *)
                        * (* Nothing shared so far *)
                          intros b Hb. simpl.
                          destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                          inversion wf_int_pref' as [| eint Hstep Heint | prefint eint1 eint2 Hsteps Hstep Ht];
                            last (destruct prefint as [| ? []]; discriminate).
                          subst eint.
                          rename s0 into eregs.
                          inversion Hstep as [| | tmp1 tmp2 tmp3 tmp4 tmp5 tmp6 | | | | |];
                            subst tmp1 tmp2 tmp3 tmp4 tmp5 tmp6;
                            subst eregs.
                          specialize (Hshift0 _ Hb)
                            as [[cid bid] [Hshift' [Hrename Hrename']]].
                          destruct b as [| b']; first discriminate.
                          rewrite shift_S_Some in Hshift'.
                          injection Hshift' as ? ?; subst cid bid.
                          eexists. split; [| split].
                          -- rewrite shift_S_Some. reflexivity.
                          -- simpl. intros off v' Hload.
                             pose proof Hblock0 _ (next_block_initial_memory C_b)
                               as Hnext0.
                             erewrite Memory.load_after_store_neq in Hload;
                               last eassumption;
                               last (injection; discriminate).
                             erewrite Memory.load_after_store_neq in Hload;
                               last eassumption;
                               last (injection; discriminate).
                             simpl in *.
                             destruct b' as [| b''];
                               last (erewrite Memory.load_next_block_None in Hload;
                                     [ discriminate
                                     | eassumption
                                     | rewrite /LOCALBUF_blockid /=; apply /ssrnat.leP; lia]).
                             simpl.
                             specialize (Hrename _ _ Hload)
                               as [v'' [Hload'' Hrename'']].
                             exists v''.
                             split; assumption.
                          -- simpl. intros off v' Hload.
                             pose proof next_block_initial_memory C_b as Hnext0.
                             destruct b' as [| b''];
                               last (erewrite Memory.load_next_block_None in Hload;
                                     [ discriminate
                                     | eassumption
                                     | rewrite /LOCALBUF_blockid /=; apply /ssrnat.leP; lia]).
                             specialize (Hrename' _ _ Hload)
                               as [v'' [Hload'' Hrename'']].
                             exists v''. split.
                             ++ now simplify_memory'.
                             ++ eassumption.
                        * intros b Hnext'. simpl in Hnext'.
                          destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                          inversion wf_int_pref' as [| eint Hstep Heint | prefint eint1 eint2 Hsteps Hstep Ht];
                            last (destruct prefint as [| ? []]; discriminate).
                          subst eint.
                          rename s0 into eregs.
                          inversion Hstep as [| | tmp1 tmp2 tmp3 tmp4 tmp5 tmp6 | | | | |];
                            subst tmp1 tmp2 tmp3 tmp4 tmp5 tmp6;
                            subst eregs.
                          erewrite Memory.next_block_store_stable;
                            last eassumption.
                          erewrite Memory.next_block_store_stable;
                            last eassumption.
                          rewrite /component_buffer in C_b.
                          rewrite /Memory.next_block mkfmapfE C_b in Hnext'.
                          injection Hnext' as Hnext'.
                          rewrite ComponentMemory.nextblock_prealloc in Hnext'.
                          destruct (prog_buffers (cur_comp s)) as [buf |] eqn:Hbuf;
                            last (move: Hbuf => /dommPn;
                                                rewrite -domm_buffers => Hcontra;
                                                                           by rewrite C_b in Hcontra).
                          rewrite domm_set domm0 fsetU0 /= in Hnext'; subst b.
                          exact (Hblock0 _ (next_block_initial_memory C_b)).
                      + intros C' Hcomp Hneq.
                        simpl in Hneq. rewrite Hmain in Hneq. (* Needed for simplify_memory' *)
                        (* rewrite <- Hcomp1 in Hnext. *)
                        destruct (wfmem_ini wf_mem Logic.eq_refl Hcomp)
                          as [Hregs [Hothercomp _]].
                        specialize (Hothercomp Hneq)
                          as [Hinitflag [Hlocalbuf [Hnextblock Hsnapshot]]].
                        (* [Hinitflag [Hlocalbuf [Cmem [HCmem Hnextblock]]]]]. *)
                        right.
                        split; [| split].
                        * simplify_memory'. exact Hinitflag.
                        * simplify_memory'. exact Hlocalbuf.
                        (* erewrite Memory.load_after_store_neq; (* TODO: Add to tactic *) *)
                        (*   last exact Hstore4; *)
                        (*   last (fold C; injection; congruence). *)
                        (* simplify_memory'. *)
                        (* exact Hlocalbuf. *)
                        * split; [split |].
                          -- destruct (prog_buffers C') as [buf |] eqn:HCbuf;
                               last by (rewrite /component_buffer domm_buffers in Hcomp;
                                        move: HCbuf => /dommPn => Hcontra;
                                                                  rewrite Hcomp in Hcontra).
                             eexists. exists buf.
                             split; [| split; [| split]];
                               try reflexivity.
                             ++ destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                                inversion wf_int_pref' as [| eint Hstep Heint | prefint eint1 eint2 Hsteps Hstep Ht];
                                  last (destruct prefint as [| ? []]; discriminate).
                                subst eint.
                                rename s0 into eregs.
                                inversion Hstep as [| | tmp1 tmp2 tmp3 tmp4 tmp5 tmp6 | | | | |];
                                  subst tmp1 tmp2 tmp3 tmp4 tmp5 tmp6;
                                  subst eregs.
                                rewrite /initial_memory /= mkfmapfE.
                                unfold component_buffer in Hcomp.
                                by rewrite Hcomp HCbuf //.
                             ++ rewrite ComponentMemory.nextblock_prealloc
                                        domm_set domm0 /=.
                                by rewrite fsetU0.
                          -- destruct (mem0 C') as [Cmem |] eqn:HCmem.
                             ++ exists Cmem. split.
                                ** repeat
                                    ((erewrite <- component_memory_after_store_neq;
                                      [| eassumption | intro Hcontra; subst C'; contradiction])
                                     ||
                                       (erewrite <- component_memory_after_alloc_neq;
                                        [| eassumption | intro Hcontra; subst C'; contradiction])).
                                   exact HCmem.
                                ** rewrite /Memory.next_block HCmem in Hnextblock.
                                   now injection Hnextblock.
                             ++
                               Local Transparent Memory.load. unfold Memory.load in Hinitflag. Local Opaque Memory.load.
                               rewrite /= HCmem in Hinitflag. discriminate.
                          -- intros b Hshared.
                             rewrite -!cats1 in Hshared. simpl in Hshared.
                             inversion Hshared; now find_nil_rcons.
                    - move=> ptr cid bid off.
                      destruct (Pointer.eq ptr (Permission.data, cur_comp s, Block.local, reg_offset v)) eqn:eq_ptr;
                        move: eq_ptr =>
                                 /Pointer.eqP eq_ptr; subst;
                                 [erewrite Memory.load_after_store_eq; eauto; try by []
                                 | erewrite Memory.load_after_store_neq; eauto; clear eq_ptr].
                      destruct (Pointer.eq ptr (Permission.data, cur_comp s, Block.local, 0%Z)) eqn:eq_ptr;
                        move: eq_ptr =>
                                 /Pointer.eqP eq_ptr; subst;
                                 [erewrite Memory.load_after_store_eq; eauto; try by []
                                 | erewrite Memory.load_after_store_neq; eauto; clear eq_ptr].
                      by eapply wfmem_no_private_ptr; eauto.
                  }
                }
                {
                  destruct prefix' as [| e prefix'].
                  - rewrite cats0. now constructor.
                  - rewrite lastI in Hshift.
                    inversion Hshift. subst t1 t'.
                    inversion H.
                    + rewrite -lastI in H0. discriminate.
                    + destruct tprefix; discriminate.
                }
              + (* EConst-Ptr *)
                destruct ptr as [[[[] ptrC] ptrb] ptro].
                * inversion wf_e as [Hptr].
                  destruct (procs (cur_comp s)) as [Cprocs |] eqn:Hprocs; last discriminate.
                  move: Hptr => /andP [] => /eqP => Hcomp Hblock.
                  subst ptrC.
                  split; [| split].
                  { (** star steps *)
                    Local Transparent expr_of_const_val loc_of_reg.
                    take_steps.
                    { eapply find_procedures_of_trace; eauto.
                      - erewrite eprocst. by subst p.
                      - right. right. rewrite Et /=.
                        (* NOTE: Inlined proof, refactor lemma later. *)
                        by rewrite /procedure_ids_of_trace /comp_subtrace
                                   /= eqxx /= in_fsetU1 eqxx /=. }
                    take_steps;
                      first exact Hstore2.
                    take_steps; (* Do recursive call. *)
                      [eapply find_procedures_of_trace; eauto; by subst p|].
                    (* Done with the event. *)
                    take_steps; (* Process external call check. *)
                      first (simplify_memory'; exact Hload0init).
                    take_steps;
                      first (simplify_memory'; exact Hload0extcall).
                    take_steps.
                    apply star_refl.
                  }
                  { (** well-formed state *)
                    econstructor; try reflexivity; try eassumption.
                    { destruct s. rewrite -Hmain. exact wb. }
                    { destruct wf_stk as [top [bot [Heq [Htop Hbot]]]]; subst stk.
                      eexists ({| CS.f_component := Component.main; CS.f_arg := arg; CS.f_cont := Kstop |} :: top).
                      exists bot. rewrite -Hmain. split; [| split]; [easy | easy |].
                      elim: (callers s) bot Hbot {Star0 Star1}; trivial.
                      move=> a l IH bot [] H1 H2.
                      fold well_formed_callers in *.
                      split.
                      ++ simplify_memory.
                         destruct v; unfold INITFLAG_offset; simpl; try congruence.
                      (* destruct (a == ) eqn:eq; *)
                      (*   move: eq => /eqP eq; subst. *)
                      (* simplify_memory. *)
                      (* ** now destruct Postcond1. *)
                      (* ** rewrite -Hmem2'; last congruence. *)
                      (*    now simplify_memory. *)
                      ++ destruct H2 as [? [? [? [? [? [? [? H2]]]]]]].
                         eexists; eexists; eexists; eexists.
                         repeat split; eauto.
                    }
                    (* Reestablish memory well-formedness.
               TODO: Refactor, automate. *)
                    { (* destruct wf_mem as [wfmem_counter wfmem_meta wfmem]. *)
                      constructor.
                      - intros C_ Hcomp.
                        destruct (Nat.eqb_spec Component.main C_) as [Heq | Hneq].
                        + subst C_.
                          rewrite -Hmain. (* TODO: Rewrite Hmain earlier, avoid duplication *)
                          by simplify_memory'.
                        + simplify_memory'.
                          assert (Hload0 := wfmem_counter wf_mem Hcomp).
                          rewrite Hload0.
                          rewrite /counter_value /=.
                          move: Hneq => /eqP.
                          case: ifP;
                            last reflexivity.
                          move => /eqP => Hcontra => /eqP => Hneq.
                          rewrite Hcontra in Hneq. congruence.
                      - discriminate.
                      - intros pref ev Hprefix.
                        destruct pref as [| ? [ | ]]; try discriminate.
                        injection Hprefix as ?; subst ev.
                        split.
                        + intros C_ Hcomp Hnext.
                          destruct (Nat.eqb_spec Component.main C_) as [Heq | Hneq].
                          * subst C_.
                            simplify_memory'.
                            apply (proj1 (wfmem_extcall_ini wf_mem Logic.eq_refl) _ Hcomp).
                            congruence.
                          * subst C_. rewrite Hmain in Hneq. contradiction.
                        + intros C_ Hcomp Hnext.
                          destruct (Nat.eqb_spec Component.main C_) as [Heq | Hneq].
                          * subst C_. rewrite Hmain in Hnext. contradiction.
                          * simplify_memory'.
                            apply (proj2 (wfmem_extcall_ini wf_mem Logic.eq_refl) _ Hcomp).
                            intros ?; subst C_. contradiction.
                      - intros C_ reg Hcomp.
                        destruct (postcondition_event_registers_load reg Hregs0)
                          as [v_reg_reg [Hload0reg _]].
                        (* assert (Hload0reg := Hregs0 (Ereg_to_reg reg) _ Logic.eq_refl). *)
                        (* rewrite reg_to_Ereg_to_reg in Hload0reg. *)
                        destruct (Nat.eqb_spec Component.main C_) as [Heq | Hneq].
                        + subst C_.
                          rewrite -Hmain.
                          destruct (EregisterP reg v) as [Heq | Hneq].
                          * subst v.
                            eexists.
                            by simplify_memory'.
                          * eexists.
                            simplify_memory'.
                            exact Hload0reg.
                        + destruct (wfmem_ini wf_mem Logic.eq_refl Hcomp) as [Hregs0' _].
                          destruct (postcondition_event_registers_load reg Hregs0')
                            as [v_reg_reg' [Hload0reg' _]].
                          eexists.
                          (* assert (Hload0reg' := Hregs0' (Ereg_to_reg reg) _ Logic.eq_refl). *)
                          (* rewrite reg_to_Ereg_to_reg in Hload0reg'. *)
                          simplify_memory'. exact Hload0reg'.
                      - discriminate.
                      - intros pref ev Hprefix.
                        destruct pref as [| ? [ | ]]; try discriminate.
                        injection Hprefix as ?; subst ev.
                        split; [| split].
                        + {
                          intros reg off Hoffset.
                          destruct (wfmem_ini wf_mem Logic.eq_refl C_b) as [Hregs _].
                          destruct (EregisterP (reg_to_Ereg reg) v) as [Heq | Hneq].
                          - subst v off.
                            eexists. eexists.
                            split; [| split].
                            + by simplify_memory'.
                            + reflexivity.
                            + rename t0 into eregs.
                              destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                              inversion wf_int_pref' as [| eint Hstep Heint | prefint eint1 eint2 Hsteps Hstep Ht].
                              { subst eint.
                                inversion Hstep as [| | tmp1 tmp2 tmp3 tmp4 tmp5 tmp6 | | | | |];
                                  subst tmp1 tmp2 tmp3 tmp4 tmp5 tmp6;
                                  subst eregs;
                                  rewrite Ereg_to_reg_to_Ereg Machine.Intermediate.Register.gss;
                                  reflexivity.
                              }
                              { destruct prefint as [| ? []]; discriminate. }
                          - destruct (postcondition_event_registers_load (reg_to_Ereg reg) Hregs)
                            as [v_reg_reg [Hload0reg Hv_reg_reg]].
                            eexists. eexists.
                            split; [| split].
                            * subst off. simplify_memory.
                              -- injection. by destruct reg.
                              -- injection.
                                 move=> /reg_offset_inj => ?; subst v;
                                                           contradiction.
                            * destruct Hv_reg_reg as [|]; subst v_reg_reg;
                                reflexivity.
                            * rename t0 into eregs.
                              destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                              inversion wf_int_pref' as [| eint Hstep Heint | prefint eint1 eint2 Hsteps Hstep Ht].
                              { subst eint.
                                inversion Hstep as [| | tmp1 tmp2 tmp3 tmp4 tmp5 tmp6 | | | | |];
                                  subst tmp1 tmp2 tmp3 tmp4 tmp5 tmp6;
                                  subst eregs;
                                  rewrite Machine.Intermediate.Register.gso;
                                  last (intros ?; subst reg; now destruct v).
                                destruct (Machine.registerP reg Machine.R_COM) as [| Hreg].
                                - subst reg.
                                  rewrite (proj2 Hregs) in Hload0reg.
                                  injection Hload0reg as ?; subst v_reg_reg.
                                  now rewrite Machine.Intermediate.Register.gss.
                                - rewrite ((proj1 Hregs) _ _ Hreg Logic.eq_refl)
                                    in Hload0reg.
                                  injection Hload0reg as ?; subst v_reg_reg.
                                  rewrite Machine.Intermediate.Register.gso;
                                    last exact Hreg.
                                  rewrite /Machine.Intermediate.Register.get
                                          Machine.Intermediate.Register.reg_in_domm_init_Undef; last (apply /dommP; exists Undef; now destruct reg).
                                  by destruct reg.
                              }
                              { destruct prefint as [| ? []]; discriminate. }
                        }
                        + intros C' _ ?; subst C'. simpl. (* lookup *)
                          (* This is directly needed for the second sub-goal, but also
                     useful for the fourth one. *)
                          destruct (wfmem_ini wf_mem Logic.eq_refl C_b)
                            as [Hregs [_ Hmaincomp]].
                          specialize (Hmaincomp Hmain) as [Hinitflag [Hlocalbuf [Hshift0 Hblock0]]].
                          (* Continue. *)
                          split; [| split; [| split]].
                          * by simplify_memory'.
                          * by simplify_memory'. (* Trivial due to work up front. *)
                          * (* Nothing shared so far *)
                            intros b Hb. simpl.
                            destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                            inversion wf_int_pref' as [| eint Hstep Heint | prefint eint1 eint2 Hsteps Hstep Ht];
                              last (destruct prefint as [| ? []]; discriminate).
                            subst eint.
                            rename s0 into eregs.
                            inversion Hstep as [| | tmp1 tmp2 tmp3 tmp4 tmp5 tmp6 | | | | |];
                              subst tmp1 tmp2 tmp3 tmp4 tmp5 tmp6;
                              subst eregs.
                            specialize (Hshift0 _ Hb)
                              as [[cid bid] [Hshift' [Hrename Hrename']]].
                            destruct b as [| b']; first discriminate.
                            rewrite shift_S_Some in Hshift'.
                            injection Hshift' as ? ?; subst cid bid.
                            eexists. split; [| split].
                            -- rewrite shift_S_Some. reflexivity.
                            -- simpl. intros off v' Hload.
                               pose proof Hblock0 _ (next_block_initial_memory C_b)
                                 as Hnext0.
                               erewrite Memory.load_after_store_neq in Hload;
                                 last eassumption;
                                 last (injection; discriminate).
                               erewrite Memory.load_after_store_neq in Hload;
                                 last eassumption;
                                 last (injection; discriminate).
                               simpl in *.
                               destruct b' as [| b''];
                                 last (erewrite Memory.load_next_block_None in Hload;
                                       [ discriminate
                                       | eassumption
                                       | rewrite /LOCALBUF_blockid /=; apply /ssrnat.leP; lia]).
                               simpl.
                               specialize (Hrename _ _ Hload)
                                 as [v'' [Hload'' Hrename'']].
                               exists v''.
                               split; assumption.
                            -- simpl. intros off v' Hload.
                               pose proof next_block_initial_memory C_b as Hnext0.
                               destruct b' as [| b''];
                                 last (erewrite Memory.load_next_block_None in Hload;
                                       [ discriminate
                                       | eassumption
                                       | rewrite /LOCALBUF_blockid /=; apply /ssrnat.leP; lia]).
                               specialize (Hrename' _ _ Hload)
                                 as [v'' [Hload'' Hrename'']].
                               exists v''. split.
                               ++ now simplify_memory'.
                               ++ eassumption.
                          * intros b Hnext'. simpl in Hnext'.
                            destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                            inversion wf_int_pref' as [| eint Hstep Heint | prefint eint1 eint2 Hsteps Hstep Ht];
                              last (destruct prefint as [| ? []]; discriminate).
                            subst eint.
                            rename s0 into eregs.
                            inversion Hstep as [| | tmp1 tmp2 tmp3 tmp4 tmp5 tmp6 | | | | |];
                              subst tmp1 tmp2 tmp3 tmp4 tmp5 tmp6;
                              subst eregs.
                            erewrite Memory.next_block_store_stable;
                              last eassumption.
                            erewrite Memory.next_block_store_stable;
                              last eassumption.
                            rewrite /component_buffer in C_b.
                            rewrite /Memory.next_block mkfmapfE C_b in Hnext'.
                            injection Hnext' as Hnext'.
                            rewrite ComponentMemory.nextblock_prealloc in Hnext'.
                            destruct (prog_buffers (cur_comp s)) as [buf |] eqn:Hbuf;
                              last (move: Hbuf => /dommPn;
                                                  rewrite -domm_buffers => Hcontra;
                                                                             by rewrite C_b in Hcontra).
                            rewrite domm_set domm0 fsetU0 /= in Hnext'; subst b.
                            exact (Hblock0 _ (next_block_initial_memory C_b)).
                        + intros C' Hcomp Hneq.
                          simpl in Hneq. rewrite Hmain in Hneq. (* Needed for simplify_memory' *)
                          (* rewrite <- Hcomp1 in Hnext. *)
                          destruct (wfmem_ini wf_mem Logic.eq_refl Hcomp)
                            as [Hregs [Hothercomp _]].
                          specialize (Hothercomp Hneq)
                            as [Hinitflag [Hlocalbuf [Hnextblock Hsnapshot]]].
                          (* [Hinitflag [Hlocalbuf [Cmem [HCmem Hnextblock]]]]]. *)
                          right.
                          split; [| split].
                          * simplify_memory'. exact Hinitflag.
                          * simplify_memory'. exact Hlocalbuf.
                          (* erewrite Memory.load_after_store_neq; (* TODO: Add to tactic *) *)
                          (*   last exact Hstore4; *)
                          (*   last (fold C; injection; congruence). *)
                          (* simplify_memory'. *)
                          (* exact Hlocalbuf. *)
                          * split; [split |].
                            -- destruct (prog_buffers C') as [buf |] eqn:HCbuf;
                                 last by (rewrite /component_buffer domm_buffers in Hcomp;
                                          move: HCbuf => /dommPn => Hcontra;
                                                                    rewrite Hcomp in Hcontra).
                               eexists. exists buf.
                               split; [| split; [| split]];
                                 try reflexivity.
                               ++ destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                                  inversion wf_int_pref' as [| eint Hstep Heint | prefint eint1 eint2 Hsteps Hstep Ht];
                                    last (destruct prefint as [| ? []]; discriminate).
                                  subst eint.
                                  rename s0 into eregs.
                                  inversion Hstep as [| | tmp1 tmp2 tmp3 tmp4 tmp5 tmp6 | | | | |];
                                    subst tmp1 tmp2 tmp3 tmp4 tmp5 tmp6;
                                    subst eregs.
                                  rewrite /initial_memory /= mkfmapfE.
                                  unfold component_buffer in Hcomp.
                                  by rewrite Hcomp HCbuf //.
                               ++ rewrite ComponentMemory.nextblock_prealloc
                                          domm_set domm0 /=.
                                  by rewrite fsetU0.
                            -- destruct (mem0 C') as [Cmem |] eqn:HCmem.
                               ++ exists Cmem. split.
                                  ** repeat
                                      ((erewrite <- component_memory_after_store_neq;
                                        [| eassumption | intro Hcontra; subst C'; contradiction])
                                       ||
                                         (erewrite <- component_memory_after_alloc_neq;
                                          [| eassumption | intro Hcontra; subst C'; contradiction])).
                                     exact HCmem.
                                  ** rewrite /Memory.next_block HCmem in Hnextblock.
                                     now injection Hnextblock.
                               ++
                                 Local Transparent Memory.load. unfold Memory.load in Hinitflag. Local Opaque Memory.load.
                                 rewrite /= HCmem in Hinitflag. discriminate.
                            -- intros b Hshared.
                               rewrite -!cats1 in Hshared. simpl in Hshared.
                               inversion Hshared; now find_nil_rcons.
                      - move=> ptr cid bid off.
                        destruct (Pointer.eq ptr (Permission.data, cur_comp s, Block.local, reg_offset v)) eqn:eq_ptr;
                          move: eq_ptr =>
                                   /Pointer.eqP eq_ptr; subst;
                                   [erewrite Memory.load_after_store_eq; eauto; try by []
                                   | erewrite Memory.load_after_store_neq; eauto; clear eq_ptr].
                        destruct (Pointer.eq ptr (Permission.data, cur_comp s, Block.local, 0%Z)) eqn:eq_ptr;
                          move: eq_ptr =>
                                   /Pointer.eqP eq_ptr; subst;
                                   [erewrite Memory.load_after_store_eq; eauto; try by []
                                   | erewrite Memory.load_after_store_neq; eauto; clear eq_ptr].
                        by eapply wfmem_no_private_ptr; eauto.
                    }
                  }
                  {
                    destruct prefix' as [| e prefix'].
                    - rewrite cats0. now constructor.
                    - rewrite lastI in Hshift.
                      inversion Hshift. subst t1 t'.
                      inversion H.
                      + rewrite -lastI in H0. discriminate.
                      + destruct tprefix; discriminate.
                  }
                * inversion wf_e as [Hptr].
                  move: Hptr => /andP [] => /eqP => Hcomp => /eqP => Hblock.
                  subst ptrC ptrb.
                  split; [| split].
                  { (** star steps *)
                    Local Transparent expr_of_const_val loc_of_reg.
                    take_steps;
                      first (simplify_memory'; exact Hload0local).
                    take_steps;
                      first exact Hstore2.
                    take_steps; (* Do recursive call. *)
                      [eapply find_procedures_of_trace; eauto; by subst p|].
                    (* Done with the event. *)
                    take_steps; (* Process external call check. *)
                      first (simplify_memory'; exact Hload0init).
                    take_steps.
                    - unfold buffer_size.
                      destruct (prog_buffers Component.main) as [Cbuf |] eqn:HCbuf.
                      + assert (Hwf_buf := wf_buffers HCbuf).
                        destruct Cbuf as [sz | vs]; auto.
                        * simplify_memory; by destruct v.
                        * simplify_memory; by destruct v.
                      + simplify_memory; by destruct v.
                    (* - rewrite Nat2Z.id. exact Halloc3. *)
                    - take_steps.
                      apply star_refl.
                  }
                  { (** well-formed state *)
                    econstructor; try reflexivity; try eassumption.
                    { destruct s. rewrite -Hmain. exact wb. }
                    { destruct wf_stk as [top [bot [Heq [Htop Hbot]]]]; subst stk.
                      eexists ({| CS.f_component := Component.main; CS.f_arg := arg; CS.f_cont := Kstop |} :: top).
                      exists bot. rewrite -Hmain. split; [| split]; [easy | easy |].
                      elim: (callers s) bot Hbot {Star0 Star1}; trivial.
                      move=> a l IH bot [] H1 H2.
                      fold well_formed_callers in *.
                      split.
                      ++ simplify_memory.
                         destruct v; unfold INITFLAG_offset; simpl; try congruence.
                      (* destruct (a == ) eqn:eq; *)
                      (*   move: eq => /eqP eq; subst. *)
                      (* simplify_memory. *)
                      (* ** now destruct Postcond1. *)
                      (* ** rewrite -Hmem2'; last congruence. *)
                      (*    now simplify_memory. *)
                      ++ destruct H2 as [? [? [? [? [? [? [? H2]]]]]]].
                         eexists; eexists; eexists; eexists.
                         repeat split; eauto.
                    }
                    (* Reestablish memory well-formedness. *)
                    (*                TODO: Refactor, automate. *)
                    { (* destruct wf_mem as [wfmem_counter wfmem_meta wfmem]. *)
                      constructor.
                      - intros C_ Hcomp.
                        destruct (Nat.eqb_spec Component.main C_) as [Heq | Hneq].
                        + subst C_.
                          rewrite -Hmain. (* TODO: Rewrite Hmain earlier, avoid duplication *)
                          by simplify_memory'.
                        + simplify_memory'.
                          assert (Hload0 := wfmem_counter wf_mem Hcomp).
                          rewrite Hload0.
                          rewrite /counter_value /=.
                          move: Hneq => /eqP.
                          case: ifP;
                            last reflexivity.
                          move => /eqP => Hcontra => /eqP => Hneq.
                          rewrite Hcontra in Hneq. congruence.
                      - discriminate.
                      - intros pref ev Hprefix.
                        destruct pref as [| ? [ | ]]; try discriminate.
                        injection Hprefix as ?; subst ev.
                        split.
                        + intros C_ Hcomp Hnext.
                          destruct (Nat.eqb_spec Component.main C_) as [Heq | Hneq].
                          * subst C_.
                            simplify_memory'.
                            apply (proj1 (wfmem_extcall_ini wf_mem Logic.eq_refl) _ Hcomp).
                            congruence.
                          * subst C_. rewrite Hmain in Hneq. contradiction.
                        + intros C_ Hcomp Hnext.
                          destruct (Nat.eqb_spec Component.main C_) as [Heq | Hneq].
                          * subst C_. rewrite Hmain in Hnext. contradiction.
                          * simplify_memory'.
                            apply (proj2 (wfmem_extcall_ini wf_mem Logic.eq_refl) _ Hcomp).
                            intros ?; subst C_. contradiction.
                      - intros C_ reg Hcomp.
                        destruct (postcondition_event_registers_load reg Hregs0)
                          as [v_reg_reg [Hload0reg _]].
                        (* assert (Hload0reg := Hregs0 (Ereg_to_reg reg) _ Logic.eq_refl). *)
                        (* rewrite reg_to_Ereg_to_reg in Hload0reg. *)
                        destruct (Nat.eqb_spec Component.main C_) as [Heq | Hneq].
                        + subst C_.
                          rewrite -Hmain.
                          destruct (EregisterP reg v) as [Heq | Hneq].
                          * subst v.
                            eexists.
                            by simplify_memory'.
                          * eexists.
                            simplify_memory'.
                            exact Hload0reg.
                        + destruct (wfmem_ini wf_mem Logic.eq_refl Hcomp) as [Hregs0' _].
                          destruct (postcondition_event_registers_load reg Hregs0')
                            as [v_reg_reg' [Hload0reg' _]].
                          eexists.
                          (* assert (Hload0reg' := Hregs0' (Ereg_to_reg reg) _ Logic.eq_refl). *)
                          (* rewrite reg_to_Ereg_to_reg in Hload0reg'. *)
                          simplify_memory'. exact Hload0reg'.
                      - discriminate.
                      - intros pref ev Hprefix.
                        destruct pref as [| ? [ | ]]; try discriminate.
                        injection Hprefix as ?; subst ev.
                        split; [| split].
                        + {
                          intros reg off Hoffset.
                          destruct (wfmem_ini wf_mem Logic.eq_refl C_b) as [Hregs _].
                          destruct (EregisterP (reg_to_Ereg reg) v) as [Heq | Hneq].
                          - subst v off.
                            eexists. eexists.
                            split; [| split].
                            + by simplify_memory'.
                            + reflexivity.
                            + rename t0 into eregs.
                              destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                              inversion wf_int_pref' as [| eint Hstep Heint | prefint eint1 eint2 Hsteps Hstep Ht].
                              { subst eint.
                                inversion Hstep as [| | tmp1 tmp2 tmp3 tmp4 tmp5 tmp6 | | | | |];
                                  subst tmp1 tmp2 tmp3 tmp4 tmp5 tmp6;
                                  subst eregs;
                                  rewrite Ereg_to_reg_to_Ereg Machine.Intermediate.Register.gss;
                                  reflexivity.
                              }
                              { destruct prefint as [| ? []]; discriminate. }
                          - destruct (postcondition_event_registers_load (reg_to_Ereg reg) Hregs)
                            as [v_reg_reg [Hload0reg Hv_reg_reg]].
                            eexists. eexists.
                            split; [| split].
                            * subst off. simplify_memory.
                              -- injection. by destruct reg.
                              -- injection.
                                 move=> /reg_offset_inj => ?; subst v;
                                                           contradiction.

                            * destruct Hv_reg_reg as [|]; subst v_reg_reg;
                                reflexivity.
                            * rename t0 into eregs.
                              destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                              inversion wf_int_pref' as [| eint Hstep Heint | prefint eint1 eint2 Hsteps Hstep Ht].
                              { subst eint.
                                inversion Hstep as [| | tmp1 tmp2 tmp3 tmp4 tmp5 tmp6 | | | | |];
                                  subst tmp1 tmp2 tmp3 tmp4 tmp5 tmp6;
                                  subst eregs;
                                  rewrite Machine.Intermediate.Register.gso;
                                  last (intros ?; subst reg; now destruct v).
                                destruct (Machine.registerP reg Machine.R_COM) as [| Hreg].
                                - subst reg.
                                  rewrite (proj2 Hregs) in Hload0reg.
                                  injection Hload0reg as ?; subst v_reg_reg.
                                  now rewrite Machine.Intermediate.Register.gss.
                                - rewrite ((proj1 Hregs) _ _ Hreg Logic.eq_refl)
                                    in Hload0reg.
                                  injection Hload0reg as ?; subst v_reg_reg.
                                  rewrite Machine.Intermediate.Register.gso;
                                    last exact Hreg.
                                  rewrite /Machine.Intermediate.Register.get
                                          Machine.Intermediate.Register.reg_in_domm_init_Undef; last (apply /dommP; exists Undef; now destruct reg).
                                  by destruct reg.
                              }
                              { destruct prefint as [| ? []]; discriminate. }
                        }
                        + intros C' _ ?; subst C'. simpl. (* lookup *)
                          (* This is directly needed for the second sub-goal, but also *)
                          (*                      useful for the fourth one. *)
                          destruct (wfmem_ini wf_mem Logic.eq_refl C_b)
                            as [Hregs [_ Hmaincomp]].
                          specialize (Hmaincomp Hmain) as [Hinitflag [Hlocalbuf [Hshift0 Hblock0]]].
                          (* Continue. *)
                          split; [| split; [| split]].
                          * by simplify_memory'.
                          * by simplify_memory'. (* Trivial due to work up front. *)
                          * (* Nothing shared so far *)
                            intros b Hb. simpl.
                            destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                            inversion wf_int_pref' as [| eint Hstep Heint | prefint eint1 eint2 Hsteps Hstep Ht];
                              last (destruct prefint as [| ? []]; discriminate).
                            subst eint.
                            rename s0 into eregs.
                            inversion Hstep as [| | tmp1 tmp2 tmp3 tmp4 tmp5 tmp6 | | | | |];
                              subst tmp1 tmp2 tmp3 tmp4 tmp5 tmp6;
                              subst eregs.
                            specialize (Hshift0 _ Hb)
                              as [[cid bid] [Hshift' [Hrename Hrename']]].
                            destruct b as [| b']; first discriminate.
                            rewrite shift_S_Some in Hshift'.
                            injection Hshift' as ? ?; subst cid bid.
                            eexists. split; [| split].
                            -- rewrite shift_S_Some. reflexivity.
                            -- simpl. intros off v' Hload.
                               pose proof Hblock0 _ (next_block_initial_memory C_b)
                                 as Hnext0.
                               erewrite Memory.load_after_store_neq in Hload;
                                 last eassumption;
                                 last (injection; discriminate).
                               erewrite Memory.load_after_store_neq in Hload;
                                 last eassumption;
                                 last (injection; discriminate).
                               simpl in *.
                               destruct b' as [| b''];
                                 last (erewrite Memory.load_next_block_None in Hload;
                                       [ discriminate
                                       | eassumption
                                       | rewrite /LOCALBUF_blockid /=; apply /ssrnat.leP; lia]).
                               simpl.
                               specialize (Hrename _ _ Hload)
                                 as [v'' [Hload'' Hrename'']].
                               exists v''.
                               split; assumption.
                            -- simpl. intros off v' Hload.
                               pose proof next_block_initial_memory C_b as Hnext0.
                               destruct b' as [| b''];
                                 last (erewrite Memory.load_next_block_None in Hload;
                                       [ discriminate
                                       | eassumption
                                       | rewrite /LOCALBUF_blockid /=; apply /ssrnat.leP; lia]).
                               specialize (Hrename' _ _ Hload)
                                 as [v'' [Hload'' Hrename'']].
                               exists v''. split.
                               ++ now simplify_memory'.
                               ++ eassumption.
                          * intros b Hnext'. simpl in Hnext'.
                            destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                            inversion wf_int_pref' as [| eint Hstep Heint | prefint eint1 eint2 Hsteps Hstep Ht];
                              last (destruct prefint as [| ? []]; discriminate).
                            subst eint.
                            rename s0 into eregs.
                            inversion Hstep as [| | tmp1 tmp2 tmp3 tmp4 tmp5 tmp6 | | | | |];
                              subst tmp1 tmp2 tmp3 tmp4 tmp5 tmp6;
                              subst eregs.
                            erewrite Memory.next_block_store_stable;
                              last eassumption.
                            erewrite Memory.next_block_store_stable;
                              last eassumption.
                            rewrite /component_buffer in C_b.
                            rewrite /Memory.next_block mkfmapfE C_b in Hnext'.
                            injection Hnext' as Hnext'.
                            rewrite ComponentMemory.nextblock_prealloc in Hnext'.
                            destruct (prog_buffers (cur_comp s)) as [buf |] eqn:Hbuf;
                              last (move: Hbuf => /dommPn;
                                                  rewrite -domm_buffers => Hcontra;
                                                                             by rewrite C_b in Hcontra).
                            rewrite domm_set domm0 fsetU0 /= in Hnext'; subst b.
                            exact (Hblock0 _ (next_block_initial_memory C_b)).
                        + intros C' Hcomp Hneq.
                          simpl in Hneq. rewrite Hmain in Hneq. (* Needed for simplify_memory' *)
                          (* rewrite <- Hcomp1 in Hnext. *)
                          destruct (wfmem_ini wf_mem Logic.eq_refl Hcomp)
                            as [Hregs [Hothercomp _]].
                          specialize (Hothercomp Hneq)
                            as [Hinitflag [Hlocalbuf [Hnextblock Hsnapshot]]].
                          (* [Hinitflag [Hlocalbuf [Cmem [HCmem Hnextblock]]]]]. *)
                          right.
                          split; [| split].
                          * simplify_memory'. exact Hinitflag.
                          * simplify_memory'. exact Hlocalbuf.
                          (* erewrite Memory.load_after_store_neq; (* TODO: Add to tactic *) *)
                          (*   last exact Hstore4; *)
                          (*   last (fold C; injection; congruence). *)
                          (* simplify_memory'. *)
                          (* exact Hlocalbuf. *)
                          * split; [split |].
                            -- destruct (prog_buffers C') as [buf |] eqn:HCbuf;
                                 last by (rewrite /component_buffer domm_buffers in Hcomp;
                                          move: HCbuf => /dommPn => Hcontra;
                                                                    rewrite Hcomp in Hcontra).
                               eexists. exists buf.
                               split; [| split; [| split]];
                                 try reflexivity.
                               ++ destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                                  inversion wf_int_pref' as [| eint Hstep Heint | prefint eint1 eint2 Hsteps Hstep Ht];
                                    last (destruct prefint as [| ? []]; discriminate).
                                  subst eint.
                                  rename s0 into eregs.
                                  inversion Hstep as [| | tmp1 tmp2 tmp3 tmp4 tmp5 tmp6 | | | | |];
                                    subst tmp1 tmp2 tmp3 tmp4 tmp5 tmp6;
                                    subst eregs.
                                  rewrite /initial_memory /= mkfmapfE.
                                  unfold component_buffer in Hcomp.
                                  by rewrite Hcomp HCbuf //.
                               ++ rewrite ComponentMemory.nextblock_prealloc
                                          domm_set domm0 /=.
                                  by rewrite fsetU0.
                            -- destruct (mem0 C') as [Cmem |] eqn:HCmem.
                               ++ exists Cmem. split.
                                  ** repeat
                                      ((erewrite <- component_memory_after_store_neq;
                                        [| eassumption | intro Hcontra; subst C'; contradiction])
                                       ||
                                         (erewrite <- component_memory_after_alloc_neq;
                                          [| eassumption | intro Hcontra; subst C'; contradiction])).
                                     exact HCmem.
                                  ** rewrite /Memory.next_block HCmem in Hnextblock.
                                     now injection Hnextblock.
                               ++
                                 Local Transparent Memory.load. unfold Memory.load in Hinitflag. Local Opaque Memory.load.
                                 rewrite /= HCmem in Hinitflag. discriminate.
                            -- intros b Hshared.
                               rewrite -!cats1 in Hshared. simpl in Hshared.
                               inversion Hshared; now find_nil_rcons.
                      - move=> ptr cid bid off.
                        destruct (Pointer.eq ptr (Permission.data, cur_comp s, Block.local, reg_offset v)) eqn:eq_ptr;
                          move: eq_ptr =>
                                   /Pointer.eqP eq_ptr; subst;
                                   [erewrite Memory.load_after_store_eq; eauto; try by []
                                   | erewrite Memory.load_after_store_neq; eauto; clear eq_ptr].
                        unfold saved. simpl. intros R; inversion R; by [].
                        destruct (Pointer.eq ptr (Permission.data, cur_comp s, Block.local, 0%Z)) eqn:eq_ptr;
                          move: eq_ptr =>
                                   /Pointer.eqP eq_ptr; subst;
                                   [erewrite Memory.load_after_store_eq; eauto; try by []
                                   | erewrite Memory.load_after_store_neq; eauto; clear eq_ptr].
                        by eapply wfmem_no_private_ptr; eauto.
                    }
                  }
                  {
                    destruct prefix' as [| e prefix'].
                    - rewrite cats0. now constructor.
                    - rewrite lastI in Hshift.
                      inversion Hshift. subst t1 t'.
                      inversion H.
                      + rewrite -lastI in H0. discriminate.
                      + destruct tprefix; discriminate.
                  }
              + (* EConst-Undef *)
                split; [| split].
                { (** star steps *)
                  Local Transparent expr_of_const_val loc_of_reg.
                  take_steps;
                    first exact Hstore2.
                  take_steps; (* Do recursive call. *)
                    [eapply find_procedures_of_trace; eauto; by subst p|].
                  (* Done with the event. *)
                  take_steps; (* Process external call check. *)
                    first (simplify_memory'; exact Hload0init).
                  take_steps;
                    first (simplify_memory'; exact Hload0extcall).
                  take_steps.
                  apply star_refl.
                }
                { (** well-formed state *)
                  econstructor; try reflexivity; try eassumption.
                  { destruct s. rewrite -Hmain. exact wb. }
                  { destruct wf_stk as [top [bot [Heq [Htop Hbot]]]]; subst stk.
                    eexists ({| CS.f_component := Component.main; CS.f_arg := arg; CS.f_cont := Kstop |} :: top).
                    exists bot. rewrite -Hmain. split; [| split]; [easy | easy |].
                    elim: (callers s) bot Hbot {Star0 Star1}; trivial.
                    move=> a l IH bot [] H1 H2.
                    fold well_formed_callers in *.
                    split.
                    ++ simplify_memory.
                       destruct v; unfold INITFLAG_offset; simpl; try congruence.
                    (* destruct (a == ) eqn:eq; *)
                    (*   move: eq => /eqP eq; subst. *)
                    (* simplify_memory. *)
                    (* ** now destruct Postcond1. *)
                    (* ** rewrite -Hmem2'; last congruence. *)
                    (*    now simplify_memory. *)
                    ++ destruct H2 as [? [? [? [? [? [? [? H2]]]]]]].
                       eexists; eexists; eexists; eexists.
                       repeat split; eauto.
                  }
                  (* Reestablish memory well-formedness.
               TODO: Refactor, automate. *)
                  { (* destruct wf_mem as [wfmem_counter wfmem_meta wfmem]. *)
                    constructor.
                    - intros C_ Hcomp.
                      destruct (Nat.eqb_spec Component.main C_) as [Heq | Hneq].
                      + subst C_.
                        rewrite -Hmain. (* TODO: Rewrite Hmain earlier, avoid duplication *)
                        by simplify_memory'.
                      + simplify_memory'.
                        assert (Hload0 := wfmem_counter wf_mem Hcomp).
                        rewrite Hload0.
                        rewrite /counter_value /=.
                        move: Hneq => /eqP.
                        case: ifP;
                          last reflexivity.
                        move => /eqP => Hcontra => /eqP => Hneq.
                        rewrite Hcontra in Hneq. congruence.
                    - discriminate.
                    - intros pref ev Hprefix.
                      destruct pref as [| ? [ | ]]; try discriminate.
                      injection Hprefix as ?; subst ev.
                      split.
                      + intros C_ Hcomp Hnext.
                        destruct (Nat.eqb_spec Component.main C_) as [Heq | Hneq].
                        * subst C_.
                          simplify_memory'.
                          apply (proj1 (wfmem_extcall_ini wf_mem Logic.eq_refl) _ Hcomp).
                          congruence.
                        * subst C_. rewrite Hmain in Hneq. contradiction.
                      + intros C_ Hcomp Hnext.
                        destruct (Nat.eqb_spec Component.main C_) as [Heq | Hneq].
                        * subst C_. rewrite Hmain in Hnext. contradiction.
                        * simplify_memory'.
                          apply (proj2 (wfmem_extcall_ini wf_mem Logic.eq_refl) _ Hcomp).
                          intros ?; subst C_. contradiction.
                    - intros C_ reg Hcomp.
                      destruct (postcondition_event_registers_load reg Hregs0)
                        as [v_reg_reg [Hload0reg _]].
                      (* assert (Hload0reg := Hregs0 (Ereg_to_reg reg) _ Logic.eq_refl). *)
                      (* rewrite reg_to_Ereg_to_reg in Hload0reg. *)
                      destruct (Nat.eqb_spec Component.main C_) as [Heq | Hneq].
                      + subst C_.
                        rewrite -Hmain.
                        destruct (EregisterP reg v) as [Heq | Hneq].
                        * subst v.
                          eexists.
                          by simplify_memory'.
                        * eexists.
                          simplify_memory'.
                          exact Hload0reg.
                      + destruct (wfmem_ini wf_mem Logic.eq_refl Hcomp) as [Hregs0' _].
                        destruct (postcondition_event_registers_load reg Hregs0')
                          as [v_reg_reg' [Hload0reg' _]].
                        eexists.
                        (* assert (Hload0reg' := Hregs0' (Ereg_to_reg reg) _ Logic.eq_refl). *)
                        (* rewrite reg_to_Ereg_to_reg in Hload0reg'. *)
                        simplify_memory'. exact Hload0reg'.
                    - discriminate.
                    - intros pref ev Hprefix.
                      destruct pref as [| ? [ | ]]; try discriminate.
                      injection Hprefix as ?; subst ev.
                      split; [| split].
                      + {
                        intros reg off Hoffset.
                        destruct (wfmem_ini wf_mem Logic.eq_refl C_b) as [Hregs _].
                        destruct (EregisterP (reg_to_Ereg reg) v) as [Heq | Hneq].
                        - subst v off.
                          eexists. eexists.
                          split; [| split].
                          + by simplify_memory'.
                          + reflexivity.
                          + rename t0 into eregs.
                            destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                            inversion wf_int_pref' as [| eint Hstep Heint | prefint eint1 eint2 Hsteps Hstep Ht].
                            { subst eint.
                              inversion Hstep as [| | tmp1 tmp2 tmp3 tmp4 tmp5 tmp6 | | | | |];
                                subst tmp1 tmp2 tmp3 tmp4 tmp5 tmp6;
                                subst eregs;
                                rewrite Ereg_to_reg_to_Ereg Machine.Intermediate.Register.gss;
                                reflexivity.
                            }
                            { destruct prefint as [| ? []]; discriminate. }
                        - destruct (postcondition_event_registers_load (reg_to_Ereg reg) Hregs)
                          as [v_reg_reg [Hload0reg Hv_reg_reg]].
                          eexists. eexists.
                          split; [| split].
                          * subst off. simplify_memory.
                            -- injection. by destruct reg.
                            -- injection.
                               move=> /reg_offset_inj => ?; subst v;
                                                         contradiction.

                          * destruct Hv_reg_reg as [|]; subst v_reg_reg;
                              reflexivity.
                          * rename t0 into eregs.
                            destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                            inversion wf_int_pref' as [| eint Hstep Heint | prefint eint1 eint2 Hsteps Hstep Ht].
                            { subst eint.
                              inversion Hstep as [| | tmp1 tmp2 tmp3 tmp4 tmp5 tmp6 | | | | |];
                                subst tmp1 tmp2 tmp3 tmp4 tmp5 tmp6;
                                subst eregs;
                                rewrite Machine.Intermediate.Register.gso;
                                last (intros ?; subst reg; now destruct v).
                              destruct (Machine.registerP reg Machine.R_COM) as [| Hreg].
                              - subst reg.
                                rewrite (proj2 Hregs) in Hload0reg.
                                injection Hload0reg as ?; subst v_reg_reg.
                                now rewrite Machine.Intermediate.Register.gss.
                              - rewrite ((proj1 Hregs) _ _ Hreg Logic.eq_refl)
                                  in Hload0reg.
                                injection Hload0reg as ?; subst v_reg_reg.
                                rewrite Machine.Intermediate.Register.gso;
                                  last exact Hreg.
                                rewrite /Machine.Intermediate.Register.get
                                        Machine.Intermediate.Register.reg_in_domm_init_Undef; last (apply /dommP; exists Undef; now destruct reg).
                                by destruct reg.
                            }
                            { destruct prefint as [| ? []]; discriminate. }
                      }
                      + intros C' _ ?; subst C'. simpl. (* lookup *)
                        (* This is directly needed for the second sub-goal, but also
                     useful for the fourth one. *)
                        destruct (wfmem_ini wf_mem Logic.eq_refl C_b)
                          as [Hregs [_ Hmaincomp]].
                        specialize (Hmaincomp Hmain) as [Hinitflag [Hlocalbuf [Hshift0 Hblock0]]].
                        (* Continue. *)
                        split; [| split; [| split]].
                        * by simplify_memory'.
                        * by simplify_memory'. (* Trivial due to work up front. *)
                        * (* Nothing shared so far *)
                          intros b Hb. simpl.
                          destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                          inversion wf_int_pref' as [| eint Hstep Heint | prefint eint1 eint2 Hsteps Hstep Ht];
                            last (destruct prefint as [| ? []]; discriminate).
                          subst eint.
                          rename s0 into eregs.
                          inversion Hstep as [| | tmp1 tmp2 tmp3 tmp4 tmp5 tmp6 | | | | |];
                            subst tmp1 tmp2 tmp3 tmp4 tmp5 tmp6;
                            subst eregs.
                          specialize (Hshift0 _ Hb)
                            as [[cid bid] [Hshift' [Hrename Hrename']]].
                          destruct b as [| b']; first discriminate.
                          rewrite shift_S_Some in Hshift'.
                          injection Hshift' as ? ?; subst cid bid.
                          eexists. split; [| split].
                          -- rewrite shift_S_Some. reflexivity.
                          -- simpl. intros off v' Hload.
                             pose proof Hblock0 _ (next_block_initial_memory C_b)
                               as Hnext0.
                             erewrite Memory.load_after_store_neq in Hload;
                               last eassumption;
                               last (injection; discriminate).
                             erewrite Memory.load_after_store_neq in Hload;
                               last eassumption;
                               last (injection; discriminate).
                             simpl in *.
                             destruct b' as [| b''];
                               last (erewrite Memory.load_next_block_None in Hload;
                                     [ discriminate
                                     | eassumption
                                     | rewrite /LOCALBUF_blockid /=; apply /ssrnat.leP; lia]).
                             simpl.
                             specialize (Hrename _ _ Hload)
                               as [v'' [Hload'' Hrename'']].
                             exists v''.
                             split; assumption.
                          -- simpl. intros off v' Hload.
                             pose proof next_block_initial_memory C_b as Hnext0.
                             destruct b' as [| b''];
                               last (erewrite Memory.load_next_block_None in Hload;
                                     [ discriminate
                                     | eassumption
                                     | rewrite /LOCALBUF_blockid /=; apply /ssrnat.leP; lia]).
                             specialize (Hrename' _ _ Hload)
                               as [v'' [Hload'' Hrename'']].
                             exists v''. split.
                             ++ now simplify_memory'.
                             ++ eassumption.
                        * intros b Hnext'. simpl in Hnext'.
                          destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                          inversion wf_int_pref' as [| eint Hstep Heint | prefint eint1 eint2 Hsteps Hstep Ht];
                            last (destruct prefint as [| ? []]; discriminate).
                          subst eint.
                          rename s0 into eregs.
                          inversion Hstep as [| | tmp1 tmp2 tmp3 tmp4 tmp5 tmp6 | | | | |];
                            subst tmp1 tmp2 tmp3 tmp4 tmp5 tmp6;
                            subst eregs.
                          erewrite Memory.next_block_store_stable;
                            last eassumption.
                          erewrite Memory.next_block_store_stable;
                            last eassumption.
                          rewrite /component_buffer in C_b.
                          rewrite /Memory.next_block mkfmapfE C_b in Hnext'.
                          injection Hnext' as Hnext'.
                          rewrite ComponentMemory.nextblock_prealloc in Hnext'.
                          destruct (prog_buffers (cur_comp s)) as [buf |] eqn:Hbuf;
                            last (move: Hbuf => /dommPn;
                                                rewrite -domm_buffers => Hcontra;
                                                                           by rewrite C_b in Hcontra).
                          rewrite domm_set domm0 fsetU0 /= in Hnext'; subst b.
                          exact (Hblock0 _ (next_block_initial_memory C_b)).
                      + intros C' Hcomp Hneq.
                        simpl in Hneq. rewrite Hmain in Hneq. (* Needed for simplify_memory' *)
                        (* rewrite <- Hcomp1 in Hnext. *)
                        destruct (wfmem_ini wf_mem Logic.eq_refl Hcomp)
                          as [Hregs [Hothercomp _]].
                        specialize (Hothercomp Hneq)
                          as [Hinitflag [Hlocalbuf [Hnextblock Hsnapshot]]].
                        (* [Hinitflag [Hlocalbuf [Cmem [HCmem Hnextblock]]]]]. *)
                        right.
                        split; [| split].
                        * simplify_memory'. exact Hinitflag.
                        * simplify_memory'. exact Hlocalbuf.
                        * split; [split |].
                          -- destruct (prog_buffers C') as [buf |] eqn:HCbuf;
                               last by (rewrite /component_buffer domm_buffers in Hcomp;
                                        move: HCbuf => /dommPn => Hcontra;
                                                                  rewrite Hcomp in Hcontra).
                             eexists. exists buf.
                             split; [| split; [| split]];
                               try reflexivity.
                             ++ destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                                inversion wf_int_pref' as [| eint Hstep Heint | prefint eint1 eint2 Hsteps Hstep Ht];
                                  last (destruct prefint as [| ? []]; discriminate).
                                subst eint.
                                rename s0 into eregs.
                                inversion Hstep as [| | tmp1 tmp2 tmp3 tmp4 tmp5 tmp6 | | | | |];
                                  subst tmp1 tmp2 tmp3 tmp4 tmp5 tmp6;
                                  subst eregs.
                                rewrite /initial_memory /= mkfmapfE.
                                unfold component_buffer in Hcomp.
                                by rewrite Hcomp HCbuf //.
                             ++ rewrite ComponentMemory.nextblock_prealloc
                                        domm_set domm0 /=.
                                by rewrite fsetU0.
                          -- destruct (mem0 C') as [Cmem |] eqn:HCmem.
                             ++ exists Cmem. split.
                                ** repeat
                                    ((erewrite <- component_memory_after_store_neq;
                                      [| eassumption | intro Hcontra; subst C'; contradiction])
                                     ||
                                       (erewrite <- component_memory_after_alloc_neq;
                                        [| eassumption | intro Hcontra; subst C'; contradiction])).
                                   exact HCmem.
                                ** rewrite /Memory.next_block HCmem in Hnextblock.
                                   now injection Hnextblock.
                             ++
                               Local Transparent Memory.load. unfold Memory.load in Hinitflag. Local Opaque Memory.load.
                               rewrite /= HCmem in Hinitflag. discriminate.
                          -- intros b Hshared.
                             rewrite -!cats1 in Hshared. simpl in Hshared.
                             inversion Hshared; now find_nil_rcons.
                    - move=> ptr cid bid off.
                      destruct (Pointer.eq ptr (Permission.data, cur_comp s, Block.local, reg_offset v)) eqn:eq_ptr;
                        move: eq_ptr =>
                                 /Pointer.eqP eq_ptr; subst;
                                 [erewrite Memory.load_after_store_eq; eauto; try by []
                                 | erewrite Memory.load_after_store_neq; eauto; clear eq_ptr].
                      destruct (Pointer.eq ptr (Permission.data, cur_comp s, Block.local, 0%Z)) eqn:eq_ptr;
                        move: eq_ptr =>
                                 /Pointer.eqP eq_ptr; subst;
                                 [erewrite Memory.load_after_store_eq; eauto; try by []
                                 | erewrite Memory.load_after_store_neq; eauto; clear eq_ptr].
                      by eapply wfmem_no_private_ptr; eauto.
                  }
                }
                {
                  destruct prefix' as [| e prefix'].
                  - rewrite cats0. now constructor.
                  - rewrite lastI in Hshift.
                    inversion Hshift. subst t1 t'.
                    inversion H.
                    + rewrite -lastI in H0. discriminate.
                    + destruct tprefix; discriminate.
                }
            }
            (* Const does not modify the (shared) memory, therefore these two
             should be identical. *)
            destruct (well_formed_memory_store_reg_offset v ptr C_b wf_mem)
              as [mem' Hstore].
            assert (Hoffsetneq: (Permission.data, C, Block.local, 0%Z) <>
                                  (Permission.data, C, Block.local, reg_offset v))
              by (now destruct v). (* Lemma? *)
            assert (Hload : exists v',
                       Memory.load
                         mem0 (Permission.data, C, Block.local, reg_offset v) = Some v')
              by (eapply Memory.store_some_load_some; eauto).
            setoid_rewrite <- (Memory.load_after_store_neq _ _ _ _ _ Hoffsetneq Hmem)
              in Hload.
            assert (Hmem' : s0 = mem_of_event_inform e1). {
              subst prefix.
              clear -wf_int_pref'.
              destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
              move: wf_int_pref'; rewrite !cats1 => wf_int_pref.
              inversion wf_int_pref.
              - now destruct prefix0.
              - destruct prefix0. inversion H. simpl in H. now destruct prefix0.
              - apply rcons_inj in H. inversion H; subst; clear H.
                apply rcons_inj in H3. inversion H3; subst; clear H3.
                inversion H1; subst; clear H1.
                reflexivity. }
            (* NOTE: Much of this can be done up front if we case analyze the
             trace prefix at the top *)
            assert (C_next_e1: C = next_comp_of_event e1).
            { destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
              rewrite Hprefix01 in wf_ev_comps'.
              setoid_rewrite <- app_assoc in wf_ev_comps'.
              apply trace_event_components_app_r in wf_ev_comps'.
              setoid_rewrite cats1 in wf_ev_comps'.
              inversion wf_ev_comps'. rewrite lastI in H.
              apply rcons_inj in H. inversion H. subst e2. clear H.
              rewrite -cats1 in H3. apply elt_eq_unit in H3 as [? [? _]]. subst e0 t1.
              by rewrite H0.
            }

            assert (Hcomp1 : next_comp_of_event e1 = cur_comp s).
            { by auto. }
            clear C_next_e1.
            (* NOTE: Instantiations! [ptr] seems to have no effect in the proofs. *)
            (* Case analysis on concrete constant expression; all cases are
             similar.
             TODO: Refactoring. *)
            destruct ptr as [n | ptr |];
              exists (StackState C (callers s)). (* Must move the second eexists below, after the memories needed for star_refl are in scope *)
            (* eexists. (* evar (CS : state (CS.sem p)). exists CS. *) *)

            + (* EConst-Int *)
              (* Before processing the goal, introduce existential witnesses. *)
              pose proof proj1 (Memory.store_some_load_some _ _ (Int n)) Hload as [mem'' Hstore'].
              eexists. (* NOTE: Moved from above! *)
              (* Continue. *)
              split; [| split].
              * (* Evaluate steps of back-translated event first. *)
                Local Transparent expr_of_const_val loc_of_reg.
                take_steps.
                -- exact Hstore'.
                -- (* Do recursive call. *)
                  take_steps.
                  ++ eapply find_procedures_of_trace; eauto.
                     { erewrite eprocst. by subst p. }
                  ++ (* Now we are done with the event.
                        We still need to process the external call check. *)
                    take_steps.
                    ** (* TODO: Needs a new invariant that talks about the init
                           check. Assume for now that it exists, and
                           initialization has already taken place --
                           initial events?. *)
                      instantiate (1 := Int 1).
                      simpl.
                      destruct wf_mem. subst prefix. unfold C in *.
                      rewrite <- Hcomp1. rewrite <- Hcomp1 in C_b.
                      specialize (wfmem0 prefix0 e1 Logic.eq_refl)
                        as [_ [Hpostcond_steady _]].
                      specialize (Hpostcond_steady _ C_b Logic.eq_refl) as [G _].
                      rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hstore');
                        last by destruct v.
                      rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem);
                        easy.
                    ** take_steps.
                       --- assert (Hload0 := proj1 (wfmem_extcall wf_mem Hprefix01) _ C_b (Logic.eq_sym Hcomp1)).
                           rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hstore');
                             last (now destruct v). (* Trivial property of register offsets. *)
                           rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem);
                             last easy.
                           exact Hload0.
                       --- unfold invalidate_metadata.
                           take_steps.
                           apply star_refl.
              * (* Reestablish invariant. *)
                econstructor; try reflexivity; try eassumption.
                { destruct s. exact wb. }
                { destruct wf_stk as [top [bot [Heq [Htop Hbot]]]]; subst stk.
                  eexists ({| CS.f_component := C; CS.f_arg := arg; CS.f_cont := Kstop |} :: top).
                  exists bot. split; [reflexivity | split; [easy|]].
                  elim: (callers s) bot Hbot {Star0 Star1}; trivial.
                  move=> a l IH bot [] H1 H2.
                  fold well_formed_callers in *.
                  split.
                  ++ simplify_memory.
                     destruct v; unfold INITFLAG_offset; simpl; try congruence.
                  (* destruct (a == ) eqn:eq; *)
                  (*   move: eq => /eqP eq; subst. *)
                  (* simplify_memory. *)
                  (* ** now destruct Postcond1. *)
                  (* ** rewrite -Hmem2'; last congruence. *)
                  (*    now simplify_memory. *)
                  ++ destruct H2 as [? [? [? [? [? [? [? H2]]]]]]].
                     eexists; eexists; eexists; eexists.
                     repeat split; eauto.
                }
                (* Reestablish memory well-formedness.
                 TODO: Refactor, automate. *)
                { (* destruct wf_mem as [wfmem_counter wfmem_meta wfmem]. *)
                  (* instantiate (1 := mem). (* FIXME *) *)
                  constructor.
                  - intros C_ Hcomp.
                    destruct (Nat.eqb_spec C C_) as [Heq | Hneq].
                    + subst C_.
                      pose proof Memory.load_after_store_eq _ _ _ _ Hmem as Hmem0.
                      assert (Hoffsetneq' : (Permission.data, C, Block.local, reg_offset v) <> (Permission.data, C, Block.local, 0%Z))
                        by (now destruct v).
                      rewrite (Memory.load_after_store_neq _ _ _ _ _ Hoffsetneq' Hstore').
                      assumption.
                    + erewrite Memory.load_after_store_neq;
                        last eassumption;
                        last (injection; contradiction).
                      assert (Hload0 := wfmem_counter wf_mem Hcomp).
                      assert (HCneq : (Permission.data, C, Block.local, 0%Z) <> (Permission.data, C_, Block.local, 0%Z))
                        by (now injection). (* Easy contradiction. *)
                      rewrite <- (Memory.load_after_store_neq _ _ _ _ _ HCneq Hmem) in Hload0.
                      rewrite counter_value_snoc. simpl.
                      move: Hneq => /eqP.
                      case: ifP;
                        last now rewrite Z.add_0_r.
                      move => /eqP => Hcontra => /eqP => Hneq.
                      symmetry in Hcontra. contradiction.
                  - intros Hcontra. now destruct prefix.
                  - intros pref ev Hprefix.
                    apply rcons_inv in Hprefix as [? ?]; subst pref ev.
                    split.
                    + intros C_ Hcomp Hnext.
                      destruct (Nat.eqb_spec C C_) as [Heq | Hneq].
                      * subst C_.
                        rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hstore');
                          last (injection; destruct v; discriminate).
                        rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem);
                          last (injection; discriminate).
                        apply (proj1 (wfmem_extcall wf_mem Hprefix01) _ Hcomp).
                        now rewrite Hcomp1.
                      * symmetry in Hnext. contradiction.
                    + intros C_ Hcomp Hnext.
                      destruct (Nat.eqb_spec C C_) as [Heq | Hneq].
                      * subst C_. contradiction.
                      * rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hstore');
                          last (injection; destruct v; discriminate).
                        rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem);
                          last (injection; discriminate).
                        apply (proj2 (wfmem_extcall wf_mem Hprefix01) _ Hcomp).
                        intro; subst C_.
                        contradiction.
                  - intros C_ reg Hcomp.
                    destruct (Nat.eqb_spec C C_) as [Heq | Hneq].
                    + subst C_.
                      destruct (EregisterP reg v).
                      * subst v.
                        exists (Int n).
                        erewrite Memory.load_after_store_eq; try reflexivity; eassumption.
                      * erewrite Memory.load_after_store_neq;
                          last eassumption;
                          last (destruct reg; destruct v; try discriminate; contradiction). (* This kind of reasoning on register offsets can be made into a lemma as well. *)
                        rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem);
                          last (now destruct reg).
                        eapply wfmem_meta; now eauto.
                    + destruct (wfmem_meta wf_mem reg Hcomp) as [v' Hload'].
                      exists v'.
                      erewrite Memory.load_after_store_neq;
                        last eassumption;
                        last (now injection).
                      erewrite Memory.load_after_store_neq;
                        try eassumption.
                      now destruct reg.
                  - intro Hcontra. now destruct prefix.
                  - intros pref ev Hprefix.
                    apply rcons_inv in Hprefix as [? ?]; subst pref ev.
                    destruct (wfmem wf_mem Hprefix01) as [Hpostreg [Hsteady Hinitial]].
                    rename n into n0. rename v into v0. rename Hload into Hload0. rename mem' into mem'0. rename s0 into mem'. (* Trying to preserve proof script... *)
                    split; last split.
                    + (** postcondition_event_registers *)
                      {
                        subst mem'.
                        intros n off Hoffset.
                        simpl in *.
                        (* subst v prefix. *)
                        unfold postcondition_event_registers in Hpostreg.
                        destruct (Z.eqb_spec (reg_offset v0) off) as [Heq | Hneq].
                        * subst off.
                          assert (v0 = reg_to_Ereg n)
                            by (now apply reg_offset_inj in Heq).
                          subst v0.
                          (* assert (v = Int n0). { *)
                          (*   rewrite (Memory.load_after_store_eq _ _ _ _ Hstore') in Hload. *)
                          (*   now injection Hload as ?. } *)
                          (* subst v. *)
                          specialize (Hpostreg n _ Logic.eq_refl) as [v0 [v0' [Hloadv0 [Hshiftv0 Hgetv0']]]].
                          eexists. eexists.
                          split; [| split].
                          -- erewrite Memory.load_after_store_eq;
                               last exact Hstore'.
                             reflexivity.
                          -- now constructor.
                          -- destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                             inversion wf_int_pref' as [| | prefint eint1 eint2 Hsteps Hstep Ht].
                             ++ destruct prefix; discriminate. (* contra *)
                             ++ subst prefix. destruct prefix0 as [| ? [|]]; discriminate. (* contra *)
                             ++ rewrite Hprefix01 in Ht.
                                symmetry in Ht. apply cats2_inv in Ht as [? [? ?]]. subst prefint eint1 eint2.
                                inversion Hstep as [| | tmp1 tmp2 tmp3 tmp4 tmp5 tmp6 | | | | |];
                                  subst tmp1 tmp2 tmp3 tmp4 tmp5 tmp6.
                                subst t0.
                                rewrite Ereg_to_reg_to_Ereg Machine.Intermediate.Register.gss.
                                reflexivity.
                        * setoid_rewrite Hcomp1 in Hpostreg.
                          destruct (wfmem_meta wf_mem (reg_to_Ereg n) C_b)
                            as [v' Hload'].
                          rewrite Hoffset in Hload'.
                          destruct (Hpostreg n _ Logic.eq_refl)
                            as [v [v'' [Hloadv [Hshiftv Hgetv'']]]].
                          assert (v = v'). {
                            subst off. rewrite Hload' in Hloadv. congruence.
                          }
                          subst v'.
                          eexists. eexists.
                          split; [| split].
                          -- erewrite Memory.load_after_store_neq;
                               last exact Hstore';
                               last (injection; contradiction).
                             erewrite Memory.load_after_store_neq;
                               last exact Hmem;
                               last (subst off; injection; now destruct n).
                             eassumption.
                          -- eassumption.
                          -- destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                             inversion wf_int_pref' as [| | prefint eint1 eint2 Hsteps Hstep Ht].
                             ++ destruct prefix; discriminate. (* contra *)
                             ++ subst prefix. destruct prefix0 as [| ? [ | ]]; discriminate. (* contra *)
                             ++ rewrite Hprefix01 in Ht.
                                symmetry in Ht. apply cats2_inv in Ht as [? [? ?]]. subst prefint eint1 eint2.
                                inversion Hstep as [| | tmp1 tmp2 tmp3 tmp4 tmp5 tmp6 | | | | |];
                                  subst tmp1 tmp2 tmp3 tmp4 tmp5 tmp6.
                                subst t0.
                                rewrite Machine.Intermediate.Register.gso;
                                  first exact Hgetv''.
                                destruct n; destruct v0; try discriminate; contradiction.
                      }
                    + intros C' _ ?; subst C'. simpl.
                      specialize (Hsteady _ C_b (Logic.eq_sym Hcomp1))
                        as [Hinitflag [Hlocalbuf [Hsnapshot Hnextblock]]].
                      split; [|split; [| split]].
                      (* The first two sub-goals are near-identical arguments on
                       memory operations. *)
                      * erewrite Memory.load_after_store_neq;
                        last exact Hstore';
                        last (injection; now destruct v0).
                        erewrite Memory.load_after_store_neq;
                          last exact Hmem;
                          last (injection; now destruct v0).
                        exact Hinitflag.
                      * erewrite Memory.load_after_store_neq;
                          last exact Hstore';
                          last (injection; now destruct v0).
                        erewrite Memory.load_after_store_neq;
                          last exact Hmem;
                          last (injection; now destruct v0).
                        exact Hlocalbuf.
                      (* ... *)
                      * intros b Hb. simpl.
                        specialize (Hsnapshot b Hb) as [[cid bid] [Hshift' [Hrename Hrename']]].
                        destruct b as [| b']; first discriminate.
                        rewrite shift_S_Some in Hshift'.
                        injection Hshift' as ? ?; subst cid bid.
                        exists (C, b'). split; [| split].
                        -- rewrite shift_S_Some. reflexivity.
                        -- simpl. intros off v' Hload'.
                           erewrite Memory.load_after_store_neq in Hload';
                             last exact Hstore';
                             last (injection; congruence).
                           erewrite Memory.load_after_store_neq in Hload';
                             last exact Hmem;
                             last (injection; congruence).
                           simpl in Hrename.
                           specialize (Hrename off v' Hload') as [v'' [Hload'' Hrename'']].
                           exists v''. split.
                           ++ subst mem'. exact Hload''.
                           ++ exact Hrename''.
                        -- simpl. intros off v' Hload'.
                           simpl in Hrename'. subst mem'.
                           specialize (Hrename' off v' Hload') as [v'' [Hload'' Hrename'']].
                           exists v''. split.
                           ++ erewrite Memory.load_after_store_neq;
                                last exact Hstore';
                                last (injection; congruence).
                              erewrite Memory.load_after_store_neq;
                                last exact Hmem;
                                last (injection; congruence).
                              exact Hload''.
                           ++ exact Hrename''.
                      * intros next Hnext.
                        rewrite Hmem' in Hnext.
                        specialize (Hnextblock next Hnext).
                        erewrite Memory.next_block_store_stable;
                          last exact Hstore'.
                        erewrite Memory.next_block_store_stable;
                          last exact Hmem.
                        exact Hnextblock.
                    + assert (mem0_mem''_asmp: forall C,
                                 C <> cur_comp s ->
                                 mem0 C = mem'' C
                             ).
                      {
                        Local Transparent Memory.store.
                        unfold Memory.store in *.
                        Local Opaque Memory.store.
                        simpl in *.
                        destruct (mem C) eqn:eC; last discriminate.
                        destruct (mem0 C) eqn:eC2; last discriminate.
                        destruct (ComponentMemory.store
                                    s1
                                    Block.local
                                    0%Z
                                    (Int (counter_value
                                            C
                                            (prefix ++ [:: EConst
                                                           (cur_comp s)
                                                           (Int n0) v0 mem' t0]))))
                                 eqn:ecompMem;
                          last discriminate.
                        destruct (ComponentMemory.store
                                    s0 Block.local (reg_offset v0) (Int n0))
                                 eqn:ecompMem2;
                          last discriminate.
                        inversion Hstore'. inversion Hmem. subst mem mem''.
                        intros ? Hneq.
                        rewrite !setmE. unfold C.
                        assert (C0 == cur_comp s = false) as rewr. by apply /eqP.
                        by rewrite rewr.
                      }
                      rewrite Hprefix01 cats1.
                      eapply wfmem_postcondition_initial_preserved; eauto.
                      assert (p_gens_t' := p_gens_t).
                      rewrite Et Hprefix01 cats1 in p_gens_t'.
                      setoid_rewrite app_assoc in p_gens_t'.
                      setoid_rewrite cats1 in p_gens_t'.
                      destruct p_gens_t' as [s' Hstar_prefix].
                      unfold CSInvariants.CSInvariants.is_prefix in *.
                      rewrite project_non_inform_append in Hstar_prefix.
                      apply star_app_inv in Hstar_prefix as [s'' [Hstar_prefix Hstar_suffix]];
                        last by apply CS.CS.singleton_traces_non_inform.
                      exists s''. exact Hstar_prefix.
                  - move=> ptr cid bid off.
                    destruct (Pointer.eq ptr (Permission.data, cur_comp s, Block.local, reg_offset v)) eqn:eq_ptr;
                      move: eq_ptr =>
                               /Pointer.eqP eq_ptr; subst;
                               [erewrite Memory.load_after_store_eq; eauto; try by []
                               | erewrite Memory.load_after_store_neq; eauto; clear eq_ptr].
                    destruct (Pointer.eq ptr (Permission.data, cur_comp s, Block.local, 0%Z)) eqn:eq_ptr;
                      move: eq_ptr =>
                               /Pointer.eqP eq_ptr; subst;
                               [erewrite Memory.load_after_store_eq; eauto; try by []
                               | erewrite Memory.load_after_store_neq; eauto; clear eq_ptr].
                    by eapply wfmem_no_private_ptr; eauto.
                }
              * simpl.
                rewrite project_non_inform_append /=.
                rewrite -> !cats0.
                by inversion Hshift; eauto.

            + (* EConst-Ptr *)
              destruct ptr as [[[ptrp ptrC] ptrb] ptro].
              destruct ptrp.
              { (* New sub-goal: code pointer *)

                set (saved := eval_binop Add (Ptr (Permission.code, C, ptrb, 0%Z)) (Int ptro)).
                pose proof proj1 (Memory.store_some_load_some _ _ (*Ptr ptr*) saved) Hload as [mem'' Hstore'].
                simpl in wf_e.
                destruct (procs (cur_comp s)) as [Cprocs |] eqn:Hprocs;
                  last discriminate.
                destruct (wfmem wf_mem Hprefix01) as [_ [Hsteady _]].
                specialize (Hsteady _ C_b (Logic.eq_sym Hcomp1))
                  as [Hinitflag [Hlocalbuf [Hsnapshot Hnextblock]]].
                pose proof
                     proj1 (wfmem_extcall wf_mem Hprefix01) _ C_b (Logic.eq_sym Hcomp1)
                  as Hextcall.
                move: wf_e => /andP => [[]] => /eqP => ? Hprocs'; subst ptrC.
                (* Continue. *)
                (* exists (StackState C (callers s)). *)
                eexists. (* evar (CS : state (CS.sem p)). exists CS. *)
                split; [| split].
                * (* Evaluate steps of back-translated event first. *)
                  Local Transparent expr_of_const_val loc_of_reg.
                  take_steps.
                  {
                    eapply find_procedures_of_trace; eauto.
                    { erewrite eprocst. by subst p. }
                    - right. right. rewrite Et /=.
                      (* NOTE: Inlined proof, refactor lemma later. *)
                      clear. elim:prefix => [| e t IH].
                      + by rewrite /procedure_ids_of_trace /comp_subtrace
                                   /= eqxx /= in_fsetU1 eqxx /=.
                      + rewrite /= /procedure_ids_of_trace /comp_subtrace /=.
                        match goal with
                        | |- context [ C == ?X ] => destruct (C == X)
                        end.
                        * by rewrite /= in_fsetU IH orbC.
                        * by rewrite IH. }
                  take_steps;
                    first exact Hstore'.
                  take_steps;
                    [eapply find_procedures_of_trace; eauto; by subst p|].
                  take_steps;
                    first (simplify_memory'; exact Hinitflag).
                  take_steps;
                    first (simplify_memory'; exact Hextcall).
                  take_steps.
                  now apply star_refl.
                * (* Reestablish invariant. *)
                  econstructor; try reflexivity; try eassumption.
                  { destruct s. exact wb. }
                  { destruct wf_stk as [top [bot [Heq [Htop Hbot]]]]; subst stk.
                    eexists ({| CS.f_component := C; CS.f_arg := arg; CS.f_cont := Kstop |} :: top).
                    exists bot. split; [reflexivity | split; [easy |]].
                    elim: (callers s) bot Hbot {Star0 Star1}; trivial.
                    move=> a l IH bot [] H1 H2.
                    fold well_formed_callers in *.
                    split.
                    ++ simplify_memory.
                       destruct v; unfold INITFLAG_offset; simpl; try congruence.
                    (* destruct (a == ) eqn:eq; *)
                    (*   move: eq => /eqP eq; subst. *)
                    (* simplify_memory. *)
                    (* ** now destruct Postcond1. *)
                    (* ** rewrite -Hmem2'; last congruence. *)
                    (*    now simplify_memory. *)
                    ++ destruct H2 as [? [? [? [? [? [? [? H2]]]]]]].
                       eexists; eexists; eexists; eexists.
                       repeat split; eauto.
                  }
                  (* Reestablish memory well-formedness.
                 TODO: Refactor, automate. *)
                  { (* destruct wf_mem as [wfmem_counter wfmem_meta wfmem]. *)
                    (* instantiate (1 := mem). (* FIXME *) *)
                    constructor.
                    - intros C_ Hcomp.
                      destruct (Nat.eqb_spec C C_) as [Heq | Hneq].
                      + subst C_.
                        pose proof Memory.load_after_store_eq _ _ _ _ Hmem as Hmem0.
                        assert (Hoffsetneq' : (Permission.data, C, Block.local, reg_offset v) <> (Permission.data, C, Block.local, 0%Z))
                          by (now destruct v).
                        rewrite (Memory.load_after_store_neq _ _ _ _ _ Hoffsetneq' Hstore').
                        assumption.
                      + erewrite Memory.load_after_store_neq;
                          last eassumption;
                          last (injection; contradiction).
                        assert (Hload0 := wfmem_counter wf_mem Hcomp).
                        assert (HCneq : (Permission.data, C, Block.local, 0%Z) <> (Permission.data, C_, Block.local, 0%Z))
                          by (now injection). (* Easy contradiction. *)
                        rewrite <- (Memory.load_after_store_neq _ _ _ _ _ HCneq Hmem) in Hload0.
                        rewrite counter_value_snoc. simpl.
                        move: Hneq => /eqP.
                        case: ifP;
                          last now rewrite Z.add_0_r.
                        move => /eqP => Hcontra => /eqP => Hneq.
                        symmetry in Hcontra. contradiction.
                    - intros Hcontra. now destruct prefix.
                    - intros pref ev Hprefix.
                      apply rcons_inv in Hprefix as [? ?]; subst pref ev.
                      split.
                      + intros C_ Hcomp Hnext.
                        destruct (Nat.eqb_spec C C_) as [Heq | Hneq].
                        * subst C_.
                          rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hstore');
                            last (injection; destruct v; discriminate).
                          rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem);
                            last (injection; discriminate).
                          apply (proj1 (wfmem_extcall wf_mem Hprefix01) _ Hcomp).
                          now rewrite Hcomp1.
                        * symmetry in Hnext. contradiction.
                      + intros C_ Hcomp Hnext.
                        destruct (Nat.eqb_spec C C_) as [Heq | Hneq].
                        * subst C_. contradiction.
                        * rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hstore');
                            last (injection; destruct v; discriminate).
                          rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem);
                            last (injection; discriminate).
                          apply (proj2 (wfmem_extcall wf_mem Hprefix01) _ Hcomp).
                          intro; subst C_.
                          contradiction.
                    - intros C_ reg Hcomp.
                      destruct (Nat.eqb_spec C C_) as [Heq | Hneq].
                      + subst C_.
                        destruct (EregisterP reg v).
                        * subst v.
                          exists saved.
                          erewrite Memory.load_after_store_eq; try reflexivity; eassumption.
                        * erewrite Memory.load_after_store_neq;
                            last eassumption;
                            last (destruct reg; destruct v; try discriminate; contradiction). (* This kind of reasoning on register offsets can be made into a lemma as well. *)
                          rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem);
                            last (now destruct reg).
                          eapply wfmem_meta; now eauto.
                      + destruct (wfmem_meta wf_mem reg Hcomp) as [v' Hload'].
                        exists v'.
                        erewrite Memory.load_after_store_neq;
                          last eassumption;
                          last (now injection).
                        erewrite Memory.load_after_store_neq;
                          try eassumption.
                        now destruct reg.
                    - intro Hcontra. now destruct prefix.
                    - intros pref ev Hprefix.
                      apply rcons_inv in Hprefix as [? ?]; subst pref ev.
                      destruct (wfmem wf_mem Hprefix01) as [Hpostreg [Hsteady Hinitial]].
                      (* rename n into n0. *) rename v into v0. rename Hload into Hload0. rename mem' into mem'0. rename s0 into mem'. (* Trying to preserve proof script... *)
                      split; last split.
                      + (** postcondition_event_registers *)
                        {
                          subst mem'.
                          intros n off Hoffset.
                          simpl in *.
                          (* subst v prefix. *)
                          (* unfold postcondition_event_registers in Hpostreg. *)
                          destruct (Z.eqb_spec (reg_offset v0) off) as [Heq | Hneq].
                          * subst off.
                            assert (v0 = reg_to_Ereg n)
                              by (now apply reg_offset_inj in Heq).
                            subst v0.
                            (* assert (v = saved). { *)
                            (*   rewrite (Memory.load_after_store_eq _ _ _ _ Hstore') in Hload. *)
                            (*   now injection Hload as ?. } *)
                            (* subst v. *)
                            eexists. eexists.
                            split; [| split].
                            -- erewrite Memory.load_after_store_eq;
                                 last exact Hstore'.
                               reflexivity.
                            -- unfold shift_value_option,
                                 rename_value_option, rename_value_template_option,
                                 saved.
                               simpl.
                               unfold ssrnat.addn, ssrnat.subn,
                                 LOCALBUF_blockid,
                                 all_zeros_shift, uniform_shift.
                               simpl.
                               reflexivity.
                            -- destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                               inversion wf_int_pref' as [| | prefint eint1 eint2 Hsteps Hstep Ht].
                               ++ destruct prefix; discriminate. (* contra *)
                               ++ subst prefix. destruct prefix0 as [| ? [|]]; discriminate. (* contra *)
                               ++ rewrite Hprefix01 in Ht.
                                  symmetry in Ht. apply cats2_inv in Ht as [? [? ?]]. subst prefint eint1 eint2.
                                  inversion Hstep as [| | tmp1 tmp2 tmp3 tmp4 tmp5 tmp6 | | | | |];
                                    subst tmp1 tmp2 tmp3 tmp4 tmp5 tmp6.
                                  subst t0.
                                  rewrite Ereg_to_reg_to_Ereg Machine.Intermediate.Register.gss.
                                  (* This was done up front in the code case *)
                                  (* move: wf_e => /andP => [[]] => /eqP => Heq1 => /eqP => Heq2. *)
                                  (* subst ptrC ptrb. *)
                                  reflexivity.

                          * (* setoid_rewrite Hcomp1 in Hpostreg. *)
                            destruct (wfmem_meta wf_mem (reg_to_Ereg n) C_b)
                              as [v' Hload'].
                            rewrite Hoffset in Hload'.
                            specialize (Hpostreg n _ Logic.eq_refl)
                              as [v [v'' [Hloadv [Hshiftv Hgetv'']]]].
                            assert (v  = v'). {
                              subst off. rewrite -Hcomp1 Hloadv in Hload'. congruence.
                            }
                            subst v'.
                            (* exists v'. *)
                            eexists. eexists.
                            split; [| split].
                            -- erewrite Memory.load_after_store_neq;
                                 last exact Hstore';
                                 last (injection; contradiction).
                               erewrite Memory.load_after_store_neq;
                                 last exact Hmem;
                                 last (subst off; injection; now destruct n).
                               eassumption.
                            -- eassumption.
                            -- destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                               inversion wf_int_pref' as [| | prefint eint1 eint2 Hsteps Hstep Ht].
                               ++ destruct prefix; discriminate. (* contra *)
                               ++ subst prefix. destruct prefix0 as [| ? [ | ]]; discriminate. (* contra *)
                               ++ rewrite Hprefix01 in Ht.
                                  symmetry in Ht. apply cats2_inv in Ht as [? [? ?]]. subst prefint eint1 eint2.
                                  inversion Hstep as [| | tmp1 tmp2 tmp3 tmp4 tmp5 tmp6 | | | | |];
                                    subst tmp1 tmp2 tmp3 tmp4 tmp5 tmp6.
                                  subst t0.
                                  rewrite Machine.Intermediate.Register.gso;
                                    first exact Hgetv''.
                                  destruct n; destruct v0; try discriminate; contradiction.
                        }
                      + intros C' _ ?; subst C'. simpl.
                        (* Done up front *)
                        (* specialize (Hsteady _ C_b (Logic.eq_sym Hcomp1)) *)
                        (*   as [Hinitflag [Hlocalbuf [Hsnapshot Hnextblock]]]. *)
                        split; [| split; [| split]].
                        (* The first two sub-goals are near-identical arguments on
                       memory operations. *)
                        * erewrite Memory.load_after_store_neq;
                          last exact Hstore';
                          last (injection; now destruct v0).
                          erewrite Memory.load_after_store_neq;
                            last exact Hmem;
                            last (injection; now destruct v0).
                          exact Hinitflag.
                        * erewrite Memory.load_after_store_neq;
                            last exact Hstore';
                            last (injection; now destruct v0).
                          erewrite Memory.load_after_store_neq;
                            last exact Hmem;
                            last (injection; now destruct v0).
                          exact Hlocalbuf.
                        (* ... *)
                        * intros b Hb. simpl.
                          specialize (Hsnapshot b Hb) as [[cid bid] [Hshift' [Hrename Hrename']]].
                          destruct b as [| b']; first discriminate.
                          rewrite shift_S_Some in Hshift'.
                          injection Hshift' as ? ?; subst cid bid.
                          exists (C, b'). split; [| split].
                          -- rewrite shift_S_Some. reflexivity.
                          -- simpl. intros off v' Hload'.
                             erewrite Memory.load_after_store_neq in Hload';
                               last exact Hstore';
                               last (injection; congruence).
                             erewrite Memory.load_after_store_neq in Hload';
                               last exact Hmem;
                               last (injection; congruence).
                             simpl in Hrename.
                             specialize (Hrename off v' Hload') as [v'' [Hload'' Hrename'']].
                             exists v''. split.
                             ** subst mem'. exact Hload''.
                             ** exact Hrename''.
                          -- simpl. intros off v' Hload'.
                             simpl in Hrename'. subst mem'.
                             specialize (Hrename' off v' Hload') as [v'' [Hload'' Hrename'']].
                             exists v''. split.
                             ++ erewrite Memory.load_after_store_neq;
                                  last exact Hstore';
                                  last (injection; congruence).
                                erewrite Memory.load_after_store_neq;
                                  last exact Hmem;
                                  last (injection; congruence).
                                exact Hload''.
                             ++ exact Hrename''.
                        * intros next Hnext.
                          rewrite Hmem' in Hnext.
                          specialize (Hnextblock next Hnext).
                          erewrite Memory.next_block_store_stable;
                            last exact Hstore'.
                          erewrite Memory.next_block_store_stable;
                            last exact Hmem.
                          exact Hnextblock.
                      + assert (mem0_mem''_asmp: forall C,
                                   C <> cur_comp s ->
                                   mem0 C = mem'' C
                               ).
                        {
                          Local Transparent Memory.store.
                          unfold Memory.store in *.
                          Local Opaque Memory.store.
                          simpl in *.
                          destruct (mem C) eqn:eC; last discriminate.
                          destruct (mem0 C) eqn:eC2; last discriminate.
                          destruct (ComponentMemory.store
                                      s1
                                      Block.local
                                      0%Z
                                      (Int
                                         (counter_value
                                            C
                                            (prefix ++
                                                    [:: EConst
                                                       (cur_comp s)
                                                       (Ptr
                                                          (Permission.code,
                                                            cur_comp s, ptrb, ptro))
                                                       v0 mem' t0]))))
                                   eqn:ecompMem;
                            last discriminate.
                          destruct (ComponentMemory.store
                                      s0 Block.local (reg_offset v0) saved)
                                   eqn:ecompMem2;
                            last discriminate.
                          inversion Hstore'. inversion Hmem. subst mem mem''.
                          intros ? Hneq.
                          rewrite !setmE. unfold C.
                          assert (C0 == cur_comp s = false) as rewr. by apply /eqP.
                          by rewrite rewr.
                        }
                        rewrite Hprefix01 cats1.
                        eapply wfmem_postcondition_initial_preserved; eauto.
                        assert (p_gens_t' := p_gens_t).
                        rewrite Et Hprefix01 cats1 in p_gens_t'.
                        setoid_rewrite app_assoc in p_gens_t'.
                        setoid_rewrite cats1 in p_gens_t'.
                        destruct p_gens_t' as [s' Hstar_prefix].
                        unfold CSInvariants.CSInvariants.is_prefix in *.
                        rewrite project_non_inform_append in Hstar_prefix.
                        apply star_app_inv in Hstar_prefix as [s'' [Hstar_prefix Hstar_suffix]];
                          last by apply CS.CS.singleton_traces_non_inform.
                        exists s''. exact Hstar_prefix.
                    - move=> ptr cid bid off.
                      destruct (Pointer.eq ptr (Permission.data, cur_comp s, Block.local, reg_offset v)) eqn:eq_ptr;
                        move: eq_ptr =>
                                 /Pointer.eqP eq_ptr; subst;
                                 [erewrite Memory.load_after_store_eq; eauto; try by []
                                 | erewrite Memory.load_after_store_neq; eauto; clear eq_ptr].
                      destruct (Pointer.eq ptr (Permission.data, cur_comp s, Block.local, 0%Z)) eqn:eq_ptr;
                        move: eq_ptr =>
                                 /Pointer.eqP eq_ptr; subst;
                                 [erewrite Memory.load_after_store_eq; eauto; try by []
                                 | erewrite Memory.load_after_store_neq; eauto; clear eq_ptr].
                      by eapply wfmem_no_private_ptr; eauto.
                  }
                * simpl.
                  rewrite project_non_inform_append /=.
                  rewrite -> !cats0.
                  by inversion Hshift; eauto.
              }
              set (saved := (eval_binop Add (Ptr (Permission.data, C, LOCALBUF_blockid, 0%Z)) (Int ptro))).
              pose proof proj1 (Memory.store_some_load_some _ _ (*Ptr ptr*) saved) Hload as [mem'' Hstore'].
              (* Continue. *)
              (* exists (StackState C (callers s)). *)
              eexists. (* evar (CS : state (CS.sem p)). exists CS. *)
              split; [| split].
              * (* Evaluate steps of back-translated event first. *)
                Local Transparent expr_of_const_val loc_of_reg.
                take_steps.
                -- destruct (wfmem wf_mem Hprefix01) as [_ [Hsteady _]].
                   specialize (Hsteady _ C_b (Logic.eq_sym Hcomp1)) as [_ [Hlocalbuf _]].
                   erewrite Memory.load_after_store_neq;
                     last exact Hmem;
                     last (injection; discriminate).
                   exact Hlocalbuf.
                -- take_steps.
                   ++ exact Hstore'.
                   ++ take_steps.
                      ** eapply find_procedures_of_trace; eauto; by subst p. 
                      ** (* Now we are done with the event.
                          We still need to process the external call check. *)
                        take_steps.
                        --- instantiate (1 := (Int 1)).
                            simpl.
                            destruct wf_mem. subst prefix. unfold C in *.
                            rewrite <- Hcomp1. rewrite <- Hcomp1 in C_b.
                            specialize (wfmem0 prefix0 e1 Logic.eq_refl)
                              as [_ [Hpostcond_steady _]].
                            specialize (Hpostcond_steady _ C_b Logic.eq_refl) as [G _].
                            rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hstore');
                              last by destruct v.
                            rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem);
                              easy.
                        --- take_steps.
                            +++ assert (Hload0 := proj1 (wfmem_extcall wf_mem Hprefix01) _ C_b (Logic.eq_sym Hcomp1)).
                                rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hstore');
                                  last (now destruct v). (* Trivial property of register offsets. *)
                                rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem);
                                  last easy.
                                exact Hload0.
                            +++ unfold invalidate_metadata.
                                take_steps.
                                apply star_refl.
              * (* Reestablish invariant. *)
                econstructor; try reflexivity; try eassumption.
                { destruct s. exact wb. }
                { destruct wf_stk as [top [bot [Heq [Htop Hbot]]]]; subst stk.
                  eexists ({| CS.f_component := C; CS.f_arg := arg; CS.f_cont := Kstop |} :: top).
                  exists bot. split; [reflexivity | split; [easy |]].
                  elim: (callers s) bot Hbot {Star0 Star1}; trivial.
                  move=> a l IH bot [] H1 H2.
                  fold well_formed_callers in *.
                  split.
                  ++ simplify_memory.
                     destruct v; unfold INITFLAG_offset; simpl; try congruence.
                  (* destruct (a == ) eqn:eq; *)
                  (*   move: eq => /eqP eq; subst. *)
                  (* simplify_memory. *)
                  (* ** now destruct Postcond1. *)
                  (* ** rewrite -Hmem2'; last congruence. *)
                  (*    now simplify_memory. *)
                  ++ destruct H2 as [? [? [? [? [? [? [? H2]]]]]]].
                     eexists; eexists; eexists; eexists.
                     repeat split; eauto.
                }
                (* Reestablish memory well-formedness.
                 TODO: Refactor, automate. *)
                { (* destruct wf_mem as [wfmem_counter wfmem_meta wfmem]. *)
                  (* instantiate (1 := mem). (* FIXME *) *)
                  constructor.
                  - intros C_ Hcomp.
                    destruct (Nat.eqb_spec C C_) as [Heq | Hneq].
                    + subst C_.
                      pose proof Memory.load_after_store_eq _ _ _ _ Hmem as Hmem0.
                      assert (Hoffsetneq' : (Permission.data, C, Block.local, reg_offset v) <> (Permission.data, C, Block.local, 0%Z))
                        by (now destruct v).
                      rewrite (Memory.load_after_store_neq _ _ _ _ _ Hoffsetneq' Hstore').
                      assumption.
                    + erewrite Memory.load_after_store_neq;
                        last eassumption;
                        last (injection; contradiction).
                      assert (Hload0 := wfmem_counter wf_mem Hcomp).
                      assert (HCneq : (Permission.data, C, Block.local, 0%Z) <> (Permission.data, C_, Block.local, 0%Z))
                        by (now injection). (* Easy contradiction. *)
                      rewrite <- (Memory.load_after_store_neq _ _ _ _ _ HCneq Hmem) in Hload0.
                      rewrite counter_value_snoc. simpl.
                      move: Hneq => /eqP.
                      case: ifP;
                        last now rewrite Z.add_0_r.
                      move => /eqP => Hcontra => /eqP => Hneq.
                      symmetry in Hcontra. contradiction.
                  - intros Hcontra. now destruct prefix.
                  - intros pref ev Hprefix.
                    apply rcons_inv in Hprefix as [? ?]; subst pref ev.
                    split.
                    + intros C_ Hcomp Hnext.
                      destruct (Nat.eqb_spec C C_) as [Heq | Hneq].
                      * subst C_.
                        rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hstore');
                          last (injection; destruct v; discriminate).
                        rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem);
                          last (injection; discriminate).
                        apply (proj1 (wfmem_extcall wf_mem Hprefix01) _ Hcomp).
                        now rewrite Hcomp1.
                      * symmetry in Hnext. contradiction.
                    + intros C_ Hcomp Hnext.
                      destruct (Nat.eqb_spec C C_) as [Heq | Hneq].
                      * subst C_. contradiction.
                      * rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hstore');
                          last (injection; destruct v; discriminate).
                        rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem);
                          last (injection; discriminate).
                        apply (proj2 (wfmem_extcall wf_mem Hprefix01) _ Hcomp).
                        intro; subst C_.
                        contradiction.
                  - intros C_ reg Hcomp.
                    destruct (Nat.eqb_spec C C_) as [Heq | Hneq].
                    + subst C_.
                      destruct (EregisterP reg v).
                      * subst v.
                        exists saved.
                        erewrite Memory.load_after_store_eq; try reflexivity; eassumption.
                      * erewrite Memory.load_after_store_neq;
                          last eassumption;
                          last (destruct reg; destruct v; try discriminate; contradiction). (* This kind of reasoning on register offsets can be made into a lemma as well. *)
                        rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem);
                          last (now destruct reg).
                        eapply wfmem_meta; now eauto.
                    + destruct (wfmem_meta wf_mem reg Hcomp) as [v' Hload'].
                      exists v'.
                      erewrite Memory.load_after_store_neq;
                        last eassumption;
                        last (now injection).
                      erewrite Memory.load_after_store_neq;
                        try eassumption.
                      now destruct reg.
                  - intro Hcontra. now destruct prefix.
                  - intros pref ev Hprefix.
                    apply rcons_inv in Hprefix as [? ?]; subst pref ev.
                    destruct (wfmem wf_mem Hprefix01) as [Hpostreg [Hsteady Hinitial]].
                    (* rename n into n0. *) rename v into v0. rename Hload into Hload0. rename mem' into mem'0. rename s0 into mem'. (* Trying to preserve proof script... *)
                    split; last split.
                    + (** postcondition_event_registers *)
                      {
                        subst mem'.
                        intros n off Hoffset.
                        simpl in *.
                        (* subst v prefix. *)
                        (* unfold postcondition_event_registers in Hpostreg. *)
                        destruct (Z.eqb_spec (reg_offset v0) off) as [Heq | Hneq].
                        * subst off.
                          assert (v0 = reg_to_Ereg n)
                            by (now apply reg_offset_inj in Heq).
                          subst v0.
                          (* assert (v = saved). { *)
                          (*   rewrite (Memory.load_after_store_eq _ _ _ _ Hstore') in Hload. *)
                          (*   now injection Hload as ?. } *)
                          (* subst v. *)
                          eexists. eexists.
                          split; [| split].
                          -- erewrite Memory.load_after_store_eq;
                               last exact Hstore'.
                             reflexivity.
                          -- unfold shift_value_option,
                               rename_value_option, rename_value_template_option,
                               saved.
                             simpl.
                             unfold ssrnat.addn, ssrnat.subn,
                               LOCALBUF_blockid,
                               all_zeros_shift, uniform_shift.
                             simpl.
                             reflexivity.
                          -- destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                             inversion wf_int_pref' as [| | prefint eint1 eint2 Hsteps Hstep Ht].
                             ++ destruct prefix; discriminate. (* contra *)
                             ++ subst prefix. destruct prefix0 as [| ? [|]]; discriminate. (* contra *)
                             ++ rewrite Hprefix01 in Ht.
                                symmetry in Ht. apply cats2_inv in Ht as [? [? ?]]. subst prefint eint1 eint2.
                                inversion Hstep as [| | tmp1 tmp2 tmp3 tmp4 tmp5 tmp6 | | | | |];
                                  subst tmp1 tmp2 tmp3 tmp4 tmp5 tmp6.
                                subst t0.
                                rewrite Ereg_to_reg_to_Ereg Machine.Intermediate.Register.gss.
                                move: wf_e => /andP => [[]] => /eqP => Heq1 => /eqP => Heq2.
                                subst ptrC ptrb.
                                reflexivity.

                        * (* setoid_rewrite Hcomp1 in Hpostreg. *)
                          destruct (wfmem_meta wf_mem (reg_to_Ereg n) C_b)
                            as [v' Hload'].
                          rewrite Hoffset in Hload'.
                          specialize (Hpostreg n _ Logic.eq_refl)
                            as [v [v'' [Hloadv [Hshiftv Hgetv'']]]].
                          assert (v  = v'). {
                            subst off. rewrite -Hcomp1 Hloadv in Hload'. congruence.
                          }
                          subst v'.
                          (* exists v'. *)
                          eexists. eexists.
                          split; [| split].
                          -- erewrite Memory.load_after_store_neq;
                               last exact Hstore';
                               last (injection; contradiction).
                             erewrite Memory.load_after_store_neq;
                               last exact Hmem;
                               last (subst off; injection; now destruct n).
                             eassumption.
                          -- eassumption.
                          -- destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                             inversion wf_int_pref' as [| | prefint eint1 eint2 Hsteps Hstep Ht].
                             ++ destruct prefix; discriminate. (* contra *)
                             ++ subst prefix. destruct prefix0 as [| ? [ | ]]; discriminate. (* contra *)
                             ++ rewrite Hprefix01 in Ht.
                                symmetry in Ht. apply cats2_inv in Ht as [? [? ?]]. subst prefint eint1 eint2.
                                inversion Hstep as [| | tmp1 tmp2 tmp3 tmp4 tmp5 tmp6 | | | | |];
                                  subst tmp1 tmp2 tmp3 tmp4 tmp5 tmp6.
                                subst t0.
                                rewrite Machine.Intermediate.Register.gso;
                                  first exact Hgetv''.
                                destruct n; destruct v0; try discriminate; contradiction.
                      }
                    + intros C' _ ?; subst C'. simpl.
                      specialize (Hsteady _ C_b (Logic.eq_sym Hcomp1))
                        as [Hinitflag [Hlocalbuf [Hsnapshot Hnextblock]]].
                      split; [| split; [| split]].
                      (* The first two sub-goals are near-identical arguments on
                       memory operations. *)
                      * erewrite Memory.load_after_store_neq;
                        last exact Hstore';
                        last (injection; now destruct v0).
                        erewrite Memory.load_after_store_neq;
                          last exact Hmem;
                          last (injection; now destruct v0).
                        exact Hinitflag.
                      * erewrite Memory.load_after_store_neq;
                          last exact Hstore';
                          last (injection; now destruct v0).
                        erewrite Memory.load_after_store_neq;
                          last exact Hmem;
                          last (injection; now destruct v0).
                        exact Hlocalbuf.
                      (* ... *)
                      * intros b Hb. simpl.
                        specialize (Hsnapshot b Hb) as [[cid bid] [Hshift' [Hrename Hrename']]].
                        destruct b as [| b']; first discriminate.
                        rewrite shift_S_Some in Hshift'.
                        injection Hshift' as ? ?; subst cid bid.
                        exists (C, b'). split; [| split].
                        -- rewrite shift_S_Some. reflexivity.
                        -- simpl. intros off v' Hload'.
                           erewrite Memory.load_after_store_neq in Hload';
                             last exact Hstore';
                             last (injection; congruence).
                           erewrite Memory.load_after_store_neq in Hload';
                             last exact Hmem;
                             last (injection; congruence).
                           simpl in Hrename.
                           specialize (Hrename off v' Hload') as [v'' [Hload'' Hrename'']].
                           exists v''. split.
                           ** subst mem'. exact Hload''.
                           ** exact Hrename''.
                        -- simpl. intros off v' Hload'.
                           simpl in Hrename'. subst mem'.
                           specialize (Hrename' off v' Hload') as [v'' [Hload'' Hrename'']].
                           exists v''. split.
                           ++ erewrite Memory.load_after_store_neq;
                                last exact Hstore';
                                last (injection; congruence).
                              erewrite Memory.load_after_store_neq;
                                last exact Hmem;
                                last (injection; congruence).
                              exact Hload''.
                           ++ exact Hrename''.
                      * intros next Hnext.
                        rewrite Hmem' in Hnext.
                        specialize (Hnextblock next Hnext).
                        erewrite Memory.next_block_store_stable;
                          last exact Hstore'.
                        erewrite Memory.next_block_store_stable;
                          last exact Hmem.
                        exact Hnextblock.
                    + assert (mem0_mem''_asmp: forall C,
                                 C <> cur_comp s ->
                                 mem0 C = mem'' C
                             ).
                      {
                        Local Transparent Memory.store.
                        unfold Memory.store in *.
                        Local Opaque Memory.store.
                        simpl in *.
                        destruct (mem C) eqn:eC; last discriminate.
                        destruct (mem0 C) eqn:eC2; last discriminate.
                        destruct (ComponentMemory.store
                                    s1
                                    Block.local
                                    0%Z
                                    (Int
                                       (counter_value
                                          C
                                          (prefix ++
                                                  [:: EConst
                                                     (cur_comp s)
                                                     (Ptr
                                                        (Permission.data,
                                                          ptrC, ptrb, ptro))
                                                     v0 mem' t0]))))
                                 eqn:ecompMem;
                          last discriminate.
                        destruct (ComponentMemory.store
                                    s0 Block.local (reg_offset v0) saved)
                                 eqn:ecompMem2;
                          last discriminate.
                        inversion Hstore'. inversion Hmem. subst mem mem''.
                        intros ? Hneq.
                        rewrite !setmE. unfold C.
                        assert (C0 == cur_comp s = false) as rewr. by apply /eqP.
                        by rewrite rewr.
                      }
                      rewrite Hprefix01 cats1.
                      eapply wfmem_postcondition_initial_preserved; eauto.
                      assert (p_gens_t' := p_gens_t).
                      rewrite Et Hprefix01 cats1 in p_gens_t'.
                      setoid_rewrite app_assoc in p_gens_t'.
                      setoid_rewrite cats1 in p_gens_t'.
                      destruct p_gens_t' as [s' Hstar_prefix].
                      unfold CSInvariants.CSInvariants.is_prefix in *.
                      rewrite project_non_inform_append in Hstar_prefix.
                      apply star_app_inv in Hstar_prefix as [s'' [Hstar_prefix Hstar_suffix]];
                        last by apply CS.CS.singleton_traces_non_inform.
                      exists s''. exact Hstar_prefix.
                  - move=> ptr cid bid off.
                    destruct (Pointer.eq ptr (Permission.data, cur_comp s, Block.local, reg_offset v)) eqn:eq_ptr;
                      move: eq_ptr =>
                               /Pointer.eqP eq_ptr; subst;
                               [erewrite Memory.load_after_store_eq; eauto; try by []
                               | erewrite Memory.load_after_store_neq; eauto; clear eq_ptr].
                    unfold saved. simpl. intros R; inversion R; by [].
                    destruct (Pointer.eq ptr (Permission.data, cur_comp s, Block.local, 0%Z)) eqn:eq_ptr;
                      move: eq_ptr =>
                               /Pointer.eqP eq_ptr; subst;
                               [erewrite Memory.load_after_store_eq; eauto; try by []
                               | erewrite Memory.load_after_store_neq; eauto; clear eq_ptr].
                    by eapply wfmem_no_private_ptr; eauto.
                }
              * simpl.
                rewrite project_non_inform_append /=.
                rewrite -> !cats0.
                by inversion Hshift; eauto.

            + (* EConst-Undef *)
              (* Continue. *)
              pose proof proj1 (Memory.store_some_load_some _ _ Undef) Hload as [mem'' Hstore'].
              eexists. (* evar (CS : state (CS.sem p)). exists CS. *)
              split; [| split].
              * (* Evaluate steps of back-translated event first. *)
                Local Transparent expr_of_const_val loc_of_reg.
                take_steps.
                -- exact Hstore'.
                -- (* Do recursive call. *)
                  take_steps.
                  ++ eapply find_procedures_of_trace; eauto; by subst p.
                  ++ (* Now we are done with the event.
                        We still need to process the external call check. *)
                    take_steps.
                    ** (* TODO: Needs a new invariant that talks about the init
                           check. Assume for now that it exists, and
                           initialization has already taken place --
                           initial events?. *)
                      instantiate (1 := Int 1).
                      simpl.
                      destruct wf_mem. subst prefix. unfold C in *.
                      rewrite <- Hcomp1. rewrite <- Hcomp1 in C_b.
                      specialize (wfmem0 prefix0 e1 Logic.eq_refl)
                        as [_ [Hpostcond_steady _]].
                      specialize (Hpostcond_steady _ C_b Logic.eq_refl) as [G _].
                      rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hstore');
                        last by destruct v.
                      rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem);
                        easy.
                    ** take_steps.
                       --- assert (Hload0 := proj1 (wfmem_extcall wf_mem Hprefix01) _ C_b (Logic.eq_sym Hcomp1)).
                           rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hstore');
                             last (now destruct v). (* Trivial property of register offsets. *)
                           rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem);
                             last easy.
                           exact Hload0.
                       --- unfold invalidate_metadata.
                           take_steps.
                           apply star_refl.
              * (* Reestablish invariant. *)
                econstructor; try reflexivity; try eassumption.
                { destruct s. exact wb. }
                { destruct wf_stk as [top [bot [Heq [Htop Hbot]]]]; subst stk.
                  eexists ({| CS.f_component := C; CS.f_arg := arg; CS.f_cont := Kstop |} :: top).
                  exists bot. split; [reflexivity | split; [easy |]].
                  elim: (callers s) bot Hbot {Star0 Star1}; trivial.
                  move=> a l IH bot [] H1 H2.
                  fold well_formed_callers in *.
                  split.
                  ++ simplify_memory.
                     destruct v; unfold INITFLAG_offset; simpl; try congruence.
                  (* destruct (a == ) eqn:eq; *)
                  (*   move: eq => /eqP eq; subst. *)
                  (* simplify_memory. *)
                  (* ** now destruct Postcond1. *)
                  (* ** rewrite -Hmem2'; last congruence. *)
                  (*    now simplify_memory. *)
                  ++ destruct H2 as [? [? [? [? [? [? [? H2]]]]]]].
                     eexists; eexists; eexists; eexists.
                     repeat split; eauto. }
                (* Reestablish memory well-formedness.
                 TODO: Refactor, automate. *)
                { (* destruct wf_mem as [wfmem_counter wfmem_meta wfmem]. *)
                  (* instantiate (1 := mem). (* FIXME *) *)
                  constructor.
                  - intros C_ Hcomp.
                    destruct (Nat.eqb_spec C C_) as [Heq | Hneq].
                    + subst C_.
                      pose proof Memory.load_after_store_eq _ _ _ _ Hmem as Hmem0.
                      assert (Hoffsetneq' : (Permission.data, C, Block.local, reg_offset v) <> (Permission.data, C, Block.local, 0%Z))
                        by (now destruct v).
                      rewrite (Memory.load_after_store_neq _ _ _ _ _ Hoffsetneq' Hstore').
                      assumption.
                    + erewrite Memory.load_after_store_neq;
                        last eassumption;
                        last (injection; contradiction).
                      assert (Hload0 := wfmem_counter wf_mem Hcomp).
                      assert (HCneq : (Permission.data, C, Block.local, 0%Z) <> (Permission.data, C_, Block.local, 0%Z))
                        by (now injection). (* Easy contradiction. *)
                      rewrite <- (Memory.load_after_store_neq _ _ _ _ _ HCneq Hmem) in Hload0.
                      rewrite counter_value_snoc. simpl.
                      move: Hneq => /eqP.
                      case: ifP;
                        last now rewrite Z.add_0_r.
                      move => /eqP => Hcontra => /eqP => Hneq.
                      symmetry in Hcontra. contradiction.
                  - intros Hcontra. now destruct prefix.
                  - intros pref ev Hprefix.
                    apply rcons_inv in Hprefix as [? ?]; subst pref ev.
                    split.
                    + intros C_ Hcomp Hnext.
                      destruct (Nat.eqb_spec C C_) as [Heq | Hneq].
                      * subst C_.
                        rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hstore');
                          last (injection; destruct v; discriminate).
                        rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem);
                          last (injection; discriminate).
                        apply (proj1 (wfmem_extcall wf_mem Hprefix01) _ Hcomp).
                        now rewrite Hcomp1.
                      * symmetry in Hnext. contradiction.
                    + intros C_ Hcomp Hnext.
                      destruct (Nat.eqb_spec C C_) as [Heq | Hneq].
                      * subst C_. contradiction.
                      * rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hstore');
                          last (injection; destruct v; discriminate).
                        rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem);
                          last (injection; discriminate).
                        apply (proj2 (wfmem_extcall wf_mem Hprefix01) _ Hcomp).
                        intro; subst C_.
                        contradiction.
                  - intros C_ reg Hcomp.
                    destruct (Nat.eqb_spec C C_) as [Heq | Hneq].
                    + subst C_.
                      destruct (EregisterP reg v).
                      * subst v.
                        exists Undef.
                        erewrite Memory.load_after_store_eq; try reflexivity; eassumption.
                      * erewrite Memory.load_after_store_neq;
                          last eassumption;
                          last (destruct reg; destruct v; try discriminate; contradiction). (* This kind of reasoning on register offsets can be made into a lemma as well. *)
                        rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem);
                          last (now destruct reg).
                        eapply wfmem_meta; now eauto.
                    + destruct (wfmem_meta wf_mem reg Hcomp) as [v' Hload'].
                      exists v'.
                      erewrite Memory.load_after_store_neq;
                        last eassumption;
                        last (now injection).
                      erewrite Memory.load_after_store_neq;
                        try eassumption.
                      now destruct reg.
                  - intro Hcontra. now destruct prefix.
                  - intros pref ev Hprefix.
                    apply rcons_inv in Hprefix as [? ?]; subst pref ev.
                    destruct (wfmem wf_mem Hprefix01) as [Hpostreg [Hsteady Hinitial]].
                    (* rename n into n0. *) rename v into v0. rename Hload into Hload0.
                    rename mem' into mem'0. rename s0 into mem'.
                    (* Trying to preserve proof script... *)
                    split; last split.
                    + (** postcondition_event_registers *)
                      {
                        subst mem'.
                        intros n off Hoffset.
                        simpl in *.
                        (* subst v prefix. *)
                        unfold postcondition_event_registers in Hpostreg.
                        destruct (Z.eqb_spec (reg_offset v0) off) as [Heq | Hneq].
                        * subst off.
                          assert (v0 = reg_to_Ereg n)
                            by (now apply reg_offset_inj in Heq).
                          subst v0.
                          (* assert (v = Undef). { *)
                          (*   rewrite (Memory.load_after_store_eq _ _ _ _ Hstore') in Hload. *)
                          (*   now injection Hload as ?. } *)
                          (* subst v. *)
                          (* exists Undef. *)
                          eexists. eexists.
                          split; [| split].
                          -- erewrite Memory.load_after_store_eq;
                               last exact Hstore'.
                             reflexivity.
                          -- now constructor.
                          -- (* TODO: Refactor this destruct at the top, currently
                              adding quickly without breaking proofs. *)
                            destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                            inversion wf_int_pref' as [| | prefint eint1 eint2 Hsteps Hstep Ht].
                            ++ destruct prefix; discriminate. (* contra *)
                            ++ subst prefix. destruct prefix0 as [| ? [|]]; discriminate. (* contra *)
                            ++ rewrite Hprefix01 in Ht.
                               symmetry in Ht. apply cats2_inv in Ht as [? [? ?]]. subst prefint eint1 eint2.
                               inversion Hstep as [| | tmp1 tmp2 tmp3 tmp4 tmp5 tmp6 | | | | |];
                                 subst tmp1 tmp2 tmp3 tmp4 tmp5 tmp6.
                               subst t0.
                               rewrite Ereg_to_reg_to_Ereg Machine.Intermediate.Register.gss.
                               reflexivity.
                        * setoid_rewrite Hcomp1 in Hpostreg.
                          destruct (wfmem_meta wf_mem (reg_to_Ereg n) C_b)
                            as [v' Hload'].
                          rewrite Hoffset in Hload'.
                          (* assert (v = v'). { *)
                          (*   assert (Hneq0 : (Permission.data, C, Block.local, 0%Z) <> (Permission.data, cur_comp s, Block.local, off)). { *)
                          (*     subst off. now destruct (reg_to_Ereg n). *)
                          (*   } *)
                          (*   setoid_rewrite <- (Memory.load_after_store_neq _ _ _ _ _ Hneq0 Hmem) in Hload'. *)
                          (*   assert (Hneqv0 : (Permission.data, C, Block.local, reg_offset v0) <> (Permission.data, cur_comp s, Block.local, off)). { *)
                          (*     injection as ?. contradiction. *)
                          (*   } *)
                          (*   rewrite <- (Memory.load_after_store_neq _ _ _ _ _ Hneqv0 Hstore') in Hload'. *)
                          (*   rewrite Hload' in Hload. now injection Hload. *)
                          (* } *)
                          (* subst v'. *)
                          (* exists v'. *)
                          destruct (Hpostreg n _ Hoffset)
                            as [v [v'' [Hloadv [Hshiftv Hgetv'']]]].
                          eexists. eexists.
                          split; [| split].
                          -- erewrite Memory.load_after_store_neq;
                               last exact Hstore';
                               last (injection; contradiction).
                             erewrite Memory.load_after_store_neq;
                               last exact Hmem;
                               last (subst off; injection; now destruct n).
                             eassumption.
                          -- eassumption.
                          -- destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                             inversion wf_int_pref' as [| | prefint eint1 eint2 Hsteps Hstep Ht].
                             ++ destruct prefix; discriminate. (* contra *)
                             ++ subst prefix. destruct prefix0 as [| ? [ | ]]; discriminate. (* contra *)
                             ++ rewrite Hprefix01 in Ht.
                                symmetry in Ht. apply cats2_inv in Ht as [? [? ?]]. subst prefint eint1 eint2.
                                inversion Hstep as [| | tmp1 tmp2 tmp3 tmp4 tmp5 tmp6 | | | | |];
                                  subst tmp1 tmp2 tmp3 tmp4 tmp5 tmp6.
                                subst t0.
                                rewrite Machine.Intermediate.Register.gso;
                                  first exact Hgetv''.
                                destruct n; destruct v0; try discriminate; contradiction.
                      }
                    + intros C' _ ?; subst C'. simpl.
                      specialize (Hsteady _ C_b (Logic.eq_sym Hcomp1))
                        as [Hinitflag [Hlocalbuf [Hsnapshot Hnextblock]]].
                      split; [| split; [| split]].
                      (* The first two sub-goals are near-identical arguments on
                       memory operations. *)
                      * erewrite Memory.load_after_store_neq;
                        last exact Hstore';
                        last (injection; now destruct v0).
                        erewrite Memory.load_after_store_neq;
                          last exact Hmem;
                          last (injection; now destruct v0).
                        exact Hinitflag.
                      * erewrite Memory.load_after_store_neq;
                          last exact Hstore';
                          last (injection; now destruct v0).
                        erewrite Memory.load_after_store_neq;
                          last exact Hmem;
                          last (injection; now destruct v0).
                        exact Hlocalbuf.
                      (* ... *)
                      * intros b Hb. simpl.
                        specialize (Hsnapshot b Hb) as [[cid bid] [Hshift' [Hrename Hrename']]].
                        destruct b as [| b']; first discriminate.
                        rewrite shift_S_Some in Hshift'.
                        injection Hshift' as ? ?; subst cid bid.
                        exists (C, b'). split; [| split].
                        -- rewrite shift_S_Some. reflexivity.
                        -- simpl. intros off v' Hload'.
                           erewrite Memory.load_after_store_neq in Hload';
                             last exact Hstore';
                             last (injection; congruence).
                           erewrite Memory.load_after_store_neq in Hload';
                             last exact Hmem;
                             last (injection; congruence).
                           simpl in Hrename.
                           specialize (Hrename off v' Hload') as [v'' [Hload'' Hrename'']].
                           exists v''. split.
                           ++ subst mem'. exact Hload''.
                           ++ exact Hrename''.
                        -- simpl. intros off v' Hload'.
                           simpl in Hrename'. subst mem'.
                           specialize (Hrename' off v' Hload') as [v'' [Hload'' Hrename'']].
                           exists v''. split.
                           ++ erewrite Memory.load_after_store_neq;
                                last exact Hstore';
                                last (injection; congruence).
                              erewrite Memory.load_after_store_neq;
                                last exact Hmem;
                                last (injection; congruence).
                              exact Hload''.
                           ++ exact Hrename''.
                      * intros next Hnext.
                        rewrite Hmem' in Hnext.
                        specialize (Hnextblock next Hnext).
                        erewrite Memory.next_block_store_stable;
                          last exact Hstore'.
                        erewrite Memory.next_block_store_stable;
                          last exact Hmem.
                        exact Hnextblock.
                    + assert (mem0_mem''_asmp: forall C,
                                 C <> cur_comp s ->
                                 mem0 C = mem'' C
                             ).
                      {
                        Local Transparent Memory.store.
                        unfold Memory.store in *.
                        Local Opaque Memory.store.
                        simpl in *.
                        destruct (mem C) eqn:eC; last discriminate.
                        destruct (mem0 C) eqn:eC2; last discriminate.
                        destruct (ComponentMemory.store
                                    s1
                                    Block.local
                                    0%Z
                                    (Int (counter_value
                                            C
                                            (prefix ++ [:: EConst
                                                          (cur_comp s)
                                                          Undef v0 mem' t0]))))
                                 eqn:ecompMem;
                          last discriminate.
                        destruct (ComponentMemory.store
                                    s0 Block.local (reg_offset v0) Undef)
                                 eqn:ecompMem2;
                          last discriminate.
                        inversion Hstore'. inversion Hmem. subst mem mem''.
                        intros ? Hneq.
                        rewrite !setmE. unfold C.
                        assert (C0 == cur_comp s = false) as rewr. by apply /eqP.
                        by rewrite rewr.
                      }
                      rewrite Hprefix01 cats1.
                      eapply wfmem_postcondition_initial_preserved; eauto.
                      assert (p_gens_t' := p_gens_t).
                      rewrite Et Hprefix01 cats1 in p_gens_t'.
                      setoid_rewrite app_assoc in p_gens_t'.
                      setoid_rewrite cats1 in p_gens_t'.
                      destruct p_gens_t' as [s' Hstar_prefix].
                      unfold CSInvariants.CSInvariants.is_prefix in *.
                      rewrite project_non_inform_append in Hstar_prefix.
                      apply star_app_inv in Hstar_prefix as [s'' [Hstar_prefix Hstar_suffix]];
                        last by apply CS.CS.singleton_traces_non_inform.
                      exists s''. exact Hstar_prefix.
                  - move=> ptr cid bid off.
                    destruct (Pointer.eq ptr (Permission.data, cur_comp s, Block.local, reg_offset v)) eqn:eq_ptr;
                      move: eq_ptr =>
                               /Pointer.eqP eq_ptr; subst;
                               [erewrite Memory.load_after_store_eq; eauto; try by []
                               | erewrite Memory.load_after_store_neq; eauto; clear eq_ptr].
                    destruct (Pointer.eq ptr (Permission.data, cur_comp s, Block.local, 0%Z)) eqn:eq_ptr;
                      move: eq_ptr =>
                               /Pointer.eqP eq_ptr; subst;
                               [erewrite Memory.load_after_store_eq; eauto; try by []
                               | erewrite Memory.load_after_store_neq; eauto; clear eq_ptr].
                    by eapply wfmem_no_private_ptr; eauto.
                }
              * simpl.
                rewrite project_non_inform_append /=.
                rewrite -> !cats0.
                by inversion Hshift; eauto.

          - (* EMov *)
            (* Gather a few recurrent assumptions at the top. *)
            assert (prefix = [::] \/ exists prefix' e', prefix = prefix' ++ [:: e'])
              as [Hprefix | [prefix0 [e1 Hprefix01]]].
            {
              destruct prefix; first by auto.
              right. rewrite lastI -cats1. by eauto.
            }
            { (* Treat empty case separately. *)
              subst prefix. simpl in *.
              assert (Hmain : C = Component.main).
              { unfold C. rewrite Et /= in wb_trace.
                by move: wb_trace => /andP => [[]] => /eqP. }
              subst C. (* NOTE: Avoid substituting to stay close to the standard proof? *)
              destruct (wfmem_ini wf_mem Logic.eq_refl C_b)
                as [Hregs0 [_ Hmaincomp]].
              specialize (Hmaincomp Hmain)
                as [Hload0init [Hload0local Hsnapshot0]].
              destruct (postcondition_event_registers_load src Hregs0)
                as [vsrc [Hloadmem0_vsrc _]].
              (* as [v_reg_v [Hload0v _]]. *)
              assert (Hloadmem_vsrc := Hloadmem0_vsrc).
              (* assert (Hload1v := Hload0v). *)
              erewrite <- Memory.load_after_store_neq in Hloadmem_vsrc;
                last exact Hmem;
                last (injection; now destruct src).
              (* erewrite <- Memory.load_after_store_neq in Hload1v; *)
              (*   last exact Hmem; *)
              (*   last (injection; now destruct src). *)
              set saved := vsrc.
              destruct (postcondition_event_registers_load dst Hregs0)
                as [vdst [Hloadmem_vdst _]].
              erewrite <- Memory.load_after_store_neq in Hloadmem_vdst;
                last exact Hmem;
                last (injection; now destruct dst).
              pose proof proj1 (Memory.store_some_load_some _ _ saved) (ex_intro _ _ Hloadmem_vdst) as [mem'' Hstore'].

              assert (Hload0extcall := proj1 (wfmem_extcall_ini wf_mem Logic.eq_refl) _ C_b Hmain).
              exists (EMov Component.main src dst s0 t0).
              exists (StackState Component.main (callers s)).
              eexists. (* evar (CS : state (CS.sem p)). exists CS. *)
              split; [| split].
              { (** star steps *)
                Local Transparent expr_of_const_val loc_of_reg.
                take_steps;
                  first exact Hloadmem_vsrc.
                take_steps;
                  first exact Hstore'.
                take_steps; (* Do recursive call. *)
                  [eapply find_procedures_of_trace; eauto; by subst p|].
                (* Done with the event. *)
                take_steps; (* Process external call check. *)
                  first (simplify_memory'; exact Hload0init).
                take_steps;
                  first (simplify_memory'; exact Hload0extcall).
                take_steps.
                apply star_refl.
              }
              { (** well-formed state *)
                econstructor; try reflexivity; try eassumption.
                { destruct s. rewrite -Hmain. exact wb. }
                { destruct wf_stk as [top [bot [Heq [Htop Hbot]]]]; subst stk.
                  eexists ({| CS.f_component := Component.main; CS.f_arg := arg; CS.f_cont := Kstop |} :: top).
                  exists bot. rewrite -Hmain. split; [| split]; [easy | easy |].
                  elim: (callers s) bot Hbot {Star0 Star1}; trivial.
                  move=> a l IH bot [] H1 H2.
                  fold well_formed_callers in *.
                  split.
                  ++ simplify_memory.
                     destruct dst; unfold INITFLAG_offset; simpl; try congruence.
                  (* destruct (a == ) eqn:eq; *)
                  (*   move: eq => /eqP eq; subst. *)
                  (* simplify_memory. *)
                  (* ** now destruct Postcond1. *)
                  (* ** rewrite -Hmem2'; last congruence. *)
                  (*    now simplify_memory. *)
                  ++ destruct H2 as [? [? [? [? [? [? [? H2]]]]]]].
                     eexists; eexists; eexists; eexists.
                     repeat split; eauto.
                }
                (* Reestablish memory well-formedness.
                 TODO: Refactor, automate. *)
                { (* destruct wf_mem as [wfmem_counter wfmem_meta wfmem]. *)
                  constructor.
                  - intros C_ Hcomp.
                    destruct (Nat.eqb_spec Component.main C_) as [Heq | Hneq].
                    + subst C_.
                      rewrite -Hmain. (* TODO: Rewrite Hmain earlier, avoid duplication *)
                      by simplify_memory'.
                    + simplify_memory'.
                      assert (Hload0 := wfmem_counter wf_mem Hcomp).
                      rewrite Hload0.
                      rewrite /counter_value /=.
                      move: Hneq => /eqP.
                      case: ifP;
                        last reflexivity.
                      move => /eqP => Hcontra => /eqP => Hneq.
                      rewrite Hcontra in Hneq. congruence.
                  - discriminate.
                  - intros pref ev Hprefix.
                    destruct pref as [| ? [ | ]]; try discriminate.
                    injection Hprefix as ?; subst ev.
                    split.
                    + intros C_ Hcomp Hnext.
                      destruct (Nat.eqb_spec Component.main C_) as [Heq | Hneq].
                      * subst C_.
                        simplify_memory'.
                        apply (proj1 (wfmem_extcall_ini wf_mem Logic.eq_refl) _ Hcomp).
                        congruence.
                      * subst C_. rewrite Hmain in Hneq. contradiction.
                    + intros C_ Hcomp Hnext.
                      destruct (Nat.eqb_spec Component.main C_) as [Heq | Hneq].
                      * subst C_. rewrite Hmain in Hnext. contradiction.
                      * simplify_memory'.
                        apply (proj2 (wfmem_extcall_ini wf_mem Logic.eq_refl) _ Hcomp).
                        intros ?; subst C_. contradiction.
                  - intros C_ reg Hcomp.
                    destruct (postcondition_event_registers_load reg Hregs0)
                      as [v_reg_reg [Hload0reg _]].
                    (* assert (Hload0reg := Hregs0 (Ereg_to_reg reg) _ Logic.eq_refl). *)
                    (* rewrite reg_to_Ereg_to_reg in Hload0reg. *)
                    destruct (Nat.eqb_spec Component.main C_) as [Heq | Hneq].
                    + subst C_.
                      rewrite -Hmain.
                      destruct (EregisterP reg dst) as [Heq | Hneq].
                      * subst dst.
                        eexists.
                        by simplify_memory'.
                      * eexists.
                        simplify_memory'.
                        exact Hload0reg.
                    + destruct (wfmem_ini wf_mem Logic.eq_refl Hcomp) as [Hregs0' _].
                      destruct (postcondition_event_registers_load reg Hregs0')
                        as [v_reg_reg' [Hload0reg' _]].
                      eexists.
                      (* assert (Hload0reg' := Hregs0' (Ereg_to_reg reg) _ Logic.eq_refl). *)
                      (* rewrite reg_to_Ereg_to_reg in Hload0reg'. *)
                      simplify_memory'. exact Hload0reg'.
                  - discriminate.
                  - intros pref ev Hprefix.
                    destruct pref as [| ? [ | ]]; try discriminate.
                    injection Hprefix as ?; subst ev.
                    split; [| split].
                    + {
                      intros reg off Hoffset.
                      destruct (wfmem_ini wf_mem Logic.eq_refl C_b) as [Hregs _].
                      destruct (EregisterP (reg_to_Ereg reg) dst) as [Heq | Hneq].
                      - subst dst off.
                        eexists. eexists.
                        split; [| split].
                        + by simplify_memory'.
                        + destruct (EregisterP src E_R_COM) as [| Hreg].
                          * subst src.
                            rewrite (proj2 Hregs) in Hloadmem0_vsrc.
                            injection Hloadmem0_vsrc as ?; subst vsrc.
                            reflexivity.
                          * assert (Hreg' : Ereg_to_reg src <> Machine.R_COM)
                              by (destruct src; try discriminate; congruence).
                            rewrite <- (reg_to_Ereg_to_reg src) in Hloadmem0_vsrc.
                            rewrite ((proj1 Hregs) _ _ Hreg' Logic.eq_refl)
                              in Hloadmem0_vsrc.
                            injection Hloadmem0_vsrc as ?; subst vsrc.
                            reflexivity.
                        + rename t0 into eregs.
                          destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                          inversion wf_int_pref' as [| eint Hstep Heint | prefint eint1 eint2 Hsteps Hstep Ht].
                          { subst eint.
                            inversion Hstep as [| | | tmp1 tmp2 tmp3 tmp4 tmp5 tmp6 | | | |];
                              subst tmp1 tmp2 tmp3 tmp4 tmp5 tmp6;
                              subst eregs;
                              rewrite Ereg_to_reg_to_Ereg Machine.Intermediate.Register.gss.
                            destruct (EregisterP src E_R_COM) as [| Hreg].
                            - subst src.
                              rewrite (proj2 Hregs) in Hloadmem0_vsrc.
                              injection Hloadmem0_vsrc as ?; subst vsrc.
                              now rewrite Machine.Intermediate.Register.gss.
                            - assert (Hreg' : Ereg_to_reg src <> Machine.R_COM)
                                by (destruct src; try discriminate; congruence).
                              rewrite <- (reg_to_Ereg_to_reg src) in Hloadmem0_vsrc.
                              rewrite ((proj1 Hregs) _ _ Hreg' Logic.eq_refl)
                                in Hloadmem0_vsrc.
                              injection Hloadmem0_vsrc as ?; subst vsrc.
                              rewrite Machine.Intermediate.Register.gso;
                                last exact Hreg'.
                              rewrite /Machine.Intermediate.Register.get
                                      Machine.Intermediate.Register.reg_in_domm_init_Undef; last (apply /dommP; exists Undef; now destruct src).
                              by destruct src.
                          }
                          { destruct prefint as [| ? []]; discriminate. }
                      - destruct (postcondition_event_registers_load (reg_to_Ereg reg) Hregs)
                        as [v_reg_reg [Hload0reg Hv_reg_reg]].
                        eexists. eexists.
                        split; [| split].
                        * subst off. simplify_memory.
                          -- injection. by destruct reg.
                          -- injection.
                             move=> /reg_offset_inj => ?; subst dst;
                                                     contradiction.
                        * destruct Hv_reg_reg as [|]; subst v_reg_reg;
                            reflexivity.
                        * rename t0 into eregs.
                          destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                          inversion wf_int_pref' as [| eint Hstep Heint | prefint eint1 eint2 Hsteps Hstep Ht].
                          { subst eint.
                            inversion Hstep as [| | | tmp1 tmp2 tmp3 tmp4 tmp5 tmp6 | | | |];
                              subst tmp1 tmp2 tmp3 tmp4 tmp5 tmp6;
                              subst eregs;
                              simpl;
                              rewrite Machine.Intermediate.Register.gso;
                              last (intros ?; subst reg; now destruct dst).
                            destruct (Machine.registerP reg Machine.R_COM) as [| Hreg].
                            - subst reg.
                              rewrite (proj2 Hregs) in Hload0reg.
                              injection Hload0reg as ?; subst v_reg_reg.
                              now rewrite Machine.Intermediate.Register.gss.
                            - rewrite ((proj1 Hregs) _ _ Hreg Logic.eq_refl)
                                in Hload0reg.
                              injection Hload0reg as ?; subst v_reg_reg.
                              rewrite Machine.Intermediate.Register.gso;
                                last exact Hreg.
                              rewrite /Machine.Intermediate.Register.get
                                      Machine.Intermediate.Register.reg_in_domm_init_Undef; last (apply /dommP; exists Undef; now destruct reg).
                              by destruct reg.
                          }
                          { destruct prefint as [| ? []]; discriminate. }
                    }
                    + intros C' _ ?; subst C'. simpl. (* lookup *)
                      (* This is directly needed for the second sub-goal, but also
                     useful for the fourth one. *)
                      destruct (wfmem_ini wf_mem Logic.eq_refl C_b)
                        as [Hregs [_ Hmaincomp]].
                      specialize (Hmaincomp Hmain) as [Hinitflag [Hlocalbuf [Hshift0 Hblock0]]].
                      (* Continue. *)
                      split; [| split; [| split]].
                      * by simplify_memory'.
                      * by simplify_memory'. (* Trivial due to work up front. *)
                      * (* Nothing shared so far *)
                        intros b Hb. simpl.
                        destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                        inversion wf_int_pref' as [| eint Hstep Heint | prefint eint1 eint2 Hsteps Hstep Ht];
                          last (destruct prefint as [| ? []]; discriminate).
                        subst eint.
                        rename s0 into eregs.
                        inversion Hstep as [| | | tmp1 tmp2 tmp3 tmp4 tmp5 tmp6 | | | |];
                          subst tmp1 tmp2 tmp3 tmp4 tmp5 tmp6;
                          subst eregs.
                        specialize (Hshift0 _ Hb)
                          as [[cid bid] [Hshift' [Hrename Hrename']]].
                        destruct b as [| b']; first discriminate.
                        rewrite shift_S_Some in Hshift'.
                        injection Hshift' as ? ?; subst cid bid.
                        eexists. split; [| split].
                        -- rewrite shift_S_Some. reflexivity.
                        -- simpl. intros off v' Hload.
                           (* Check next_block_prepare_buffers C_b. *)
                           pose proof Hblock0 _ (next_block_initial_memory C_b)
                             as Hnext0.
                           erewrite Memory.load_after_store_neq in Hload;
                             last eassumption;
                             last (injection; discriminate).
                           erewrite Memory.load_after_store_neq in Hload;
                             last eassumption;
                             last (injection; discriminate).
                           simpl in *.
                           destruct b' as [| b''];
                             last (erewrite Memory.load_next_block_None in Hload;
                                   [ discriminate
                                   | eassumption
                                   | rewrite /LOCALBUF_blockid /=; apply /ssrnat.leP; lia]).
                           simpl.
                           specialize (Hrename _ _ Hload)
                             as [v'' [Hload'' Hrename'']].
                           exists v''.
                           split; assumption.
                        -- simpl. intros off v' Hload.
                           pose proof next_block_initial_memory C_b as Hnext0.
                           destruct b' as [| b''];
                             last (erewrite Memory.load_next_block_None in Hload;
                                   [ discriminate
                                   | eassumption
                                   | rewrite /LOCALBUF_blockid /=; apply /ssrnat.leP; lia]).
                           specialize (Hrename' _ _ Hload)
                             as [v'' [Hload'' Hrename'']].
                           exists v''. split.
                           ++ now simplify_memory'.
                           ++ eassumption.
                      * intros b Hnext'. simpl in Hnext'.
                        destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                        inversion wf_int_pref' as [| eint Hstep Heint | prefint eint1 eint2 Hsteps Hstep Ht];
                          last (destruct prefint as [| ? []]; discriminate).
                        subst eint.
                        rename s0 into eregs.
                        inversion Hstep as [| | | tmp1 tmp2 tmp3 tmp4 tmp5 tmp6| | | |];
                          subst tmp1 tmp2 tmp3 tmp4 tmp5 tmp6;
                          subst eregs.
                        erewrite Memory.next_block_store_stable;
                          last eassumption.
                        erewrite Memory.next_block_store_stable;
                          last eassumption.
                        rewrite /component_buffer in C_b.
                        rewrite /Memory.next_block mkfmapfE C_b in Hnext'.
                        injection Hnext' as Hnext'.
                        rewrite ComponentMemory.nextblock_prealloc in Hnext'.
                        destruct (prog_buffers (cur_comp s)) as [buf |] eqn:Hbuf;
                          last (move: Hbuf => /dommPn;
                                             rewrite -domm_buffers => Hcontra;
                                                                       by rewrite C_b in Hcontra).
                        rewrite domm_set domm0 fsetU0 /= in Hnext'; subst b.
                        exact (Hblock0 _ (next_block_initial_memory C_b)).
                    + intros C' Hcomp Hneq.
                      simpl in Hneq. rewrite Hmain in Hneq. (* Needed for simplify_memory' *)
                      (* rewrite <- Hcomp1 in Hnext. *)
                      destruct (wfmem_ini wf_mem Logic.eq_refl Hcomp)
                        as [Hregs [Hothercomp _]].
                      specialize (Hothercomp Hneq)
                        as [Hinitflag [Hlocalbuf [Hnextblock Hsnapshot]]].
                      (* [Hinitflag [Hlocalbuf [Cmem [HCmem Hnextblock]]]]]. *)
                      right.
                      split; [| split; [| split]].
                      * simplify_memory'. exact Hinitflag.
                      * simplify_memory'. exact Hlocalbuf.
                      * split.
                        -- destruct (prog_buffers C') as [buf |] eqn:HCbuf;
                             last by (rewrite /component_buffer domm_buffers in Hcomp;
                                      move: HCbuf => /dommPn => Hcontra;
                                                              rewrite Hcomp in Hcontra).
                           eexists. exists buf.
                           split; [| split; [| split]];
                             try reflexivity.
                           ++ destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                              inversion wf_int_pref' as [| eint Hstep Heint | prefint eint1 eint2 Hsteps Hstep Ht];
                                last (destruct prefint as [| ? []]; discriminate).
                              subst eint.
                              rename s0 into eregs.
                              inversion Hstep as [| | | tmp1 tmp2 tmp3 tmp4 tmp5 tmp6 | | | |];
                                subst tmp1 tmp2 tmp3 tmp4 tmp5 tmp6;
                                subst eregs.
                              rewrite /initial_memory /= mkfmapfE.
                              unfold component_buffer in Hcomp.
                              by rewrite Hcomp HCbuf //.
                           ++ rewrite ComponentMemory.nextblock_prealloc
                                      domm_set domm0 /=.
                              by rewrite fsetU0.
                        -- destruct (mem0 C') as [Cmem |] eqn:HCmem.
                           ++ exists Cmem. split.
                              ** repeat
                                  ((erewrite <- component_memory_after_store_neq;
                                    [| eassumption | intro Hcontra; subst C'; contradiction])
                                   ||
                                     (erewrite <- component_memory_after_alloc_neq;
                                      [| eassumption | intro Hcontra; subst C'; contradiction])).
                                 exact HCmem.
                              ** rewrite /Memory.next_block HCmem in Hnextblock.
                                 now injection Hnextblock.
                           ++
                             Local Transparent Memory.load. unfold Memory.load in Hinitflag. Local Opaque Memory.load.
                             rewrite /= HCmem in Hinitflag. discriminate.
                      * intros b Hcontra. simpl in Hcontra.
                        inversion Hcontra. now destruct t1.
                        now destruct t1.
                  - move=> ptr cid bid off.
                    destruct (Pointer.eq ptr (Permission.data, cur_comp s, Block.local, reg_offset dst)) eqn:eq_ptr;
                      move: eq_ptr =>
                               /Pointer.eqP eq_ptr; subst;
                               [erewrite Memory.load_after_store_eq; eauto; try by []
                               | erewrite Memory.load_after_store_neq; eauto; clear eq_ptr].
                    unfold saved. (* unfold saved. simpl. intros R; inversion R; by []. *)
                    destruct Hregs0 as [G1 G2].
                    destruct (Machine.register_eqb (Ereg_to_reg src) Machine.R_COM) eqn:eqreg;
                      move: eqreg => /Machine.registerP eq_reg.
                    destruct src; try discriminate. rewrite G2 in Hloadmem0_vsrc. by inversion Hloadmem0_vsrc.
                    specialize (G1 _ _ eq_reg Logic.eq_refl).
                    destruct src; try by []; rewrite G1 in Hloadmem0_vsrc; by inversion Hloadmem0_vsrc.
                    (* eapply wfmem in wf_mem as [G ?]; last eauto. *)
                    (* specialize (G  _ Logic.eq_refl) as [v1' [v2' G]]. *)
                    (* destruct G as [G1 [G2 G3]]. *)
                    (* rewrite G1 in Hvcom. inversion Hcom; subst; clear Hcom. *)
                    (* destruct vcom as [| [[[[]]]] |]; try discriminate. *)
                    (* rewrite /all_zeros_shift /uniform_shift //= *)
                    (*         /rename_addr_option /sigma_shifting_wrap_bid_in_addr *)
                    (*         /sigma_shifting_lefttoright_addr_bid *)
                    (*         /sigma_shifting_lefttoright_option in G2. *)
                    (*  destruct i0; try discriminate. simpl in G2. intros R; inversion R; by []. *)
                    destruct (Pointer.eq ptr (Permission.data, cur_comp s, Block.local, 0%Z)) eqn:eq_ptr;
                      move: eq_ptr =>
                               /Pointer.eqP eq_ptr; subst;
                               [erewrite Memory.load_after_store_eq; eauto; try by []
                               | erewrite Memory.load_after_store_neq; eauto; clear eq_ptr].
                    by eapply wfmem_no_private_ptr; eauto.
                }
              }
              {
                destruct prefix' as [| e prefix'].
                - rewrite cats0. now constructor.
                - rewrite lastI in Hshift.
                  inversion Hshift. subst t1 t'.
                  inversion H.
                  + rewrite -lastI in H0. discriminate.
                  + destruct tprefix; discriminate.
              }
            }

            (*destruct (well_formed_memory_store_reg_offset v (Int 42) C_b wf_mem) as [mem' Hstore].*) (* Mostly pollution? *)
            (* Const does not modify the (shared) memory, therefore these two
             should be identical. *)
            assert (Hmem' : s0 = mem_of_event_inform e1). {
              subst prefix.
              clear -wf_int_pref'.
              move: wf_int_pref'; rewrite !cats1 => wf_int_pref.
              destruct wf_int_pref as [wf_int_pref _].
              inversion wf_int_pref.
              - now destruct prefix0.
              - destruct prefix0. inversion H. simpl in H. now destruct prefix0.
              - apply rcons_inj in H. inversion H; subst; clear H.
                apply rcons_inj in H3. inversion H3; subst; clear H3.
                inversion H1; subst; clear H1.
                reflexivity.
            }

            assert (C_next_e1: C = next_comp_of_event e1).
            {
              destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
              rewrite Hprefix01 in wf_ev_comps'.
              setoid_rewrite <- app_assoc in wf_ev_comps'.
              apply trace_event_components_app_r in wf_ev_comps'.
              setoid_rewrite cats1 in wf_ev_comps'.
              inversion wf_ev_comps'. rewrite lastI in H.
              apply rcons_inj in H. inversion H. subst e2. clear H.
              rewrite -cats1 in H3. apply elt_eq_unit in H3 as [? [? _]]. subst e0 t1.
              by rewrite H0.
            }

            assert (Hcomp1 : next_comp_of_event e1 = cur_comp s).
            { by auto. }
            clear C_next_e1.
            (* NOTE: Instantiations! [ptr] seems to have no effect in the proofs. *)
            exists (EMov C src dst s0 t0).
            (* NOTE: Can we make this initial part more like the other cases? *)
            assert (Hoffsetneq: (Permission.data, C, Block.local, 0%Z) <> (Permission.data, C, Block.local, reg_offset dst))
              by (now destruct dst). (* Lemma? *)
            assert (Hoffsetneq2: (Permission.data, C, Block.local, 0%Z) <> (Permission.data, C, Block.local, reg_offset src))
              by (now destruct src).
            assert (Hload := wfmem_meta wf_mem dst C_b). fold C in Hload.
            setoid_rewrite <- (Memory.load_after_store_neq _ _ _ _ _ Hoffsetneq Hmem) in Hload.

            assert (exists v', Memory.load
                            mem0
                            (Permission.data, C, Block.local, (0 + reg_offset src)%Z)
                          = Some v')
              as [vsrc Hloadmem0_vsrc].
            {
              destruct wf_mem.
              specialize (wfmem_meta0 C src) as [vloadmem0 Hloadmem0]; by eauto.
            }
            assert (Memory.load
                      mem
                      (Permission.data, C, Block.local, (0 + reg_offset src)%Z)
                    = Some vsrc)
              as Hloadmem_vsrc.
            {
              by rewrite (Memory.load_after_store_neq _ _ _ _ _ Hoffsetneq2 Hmem).
            }
            set saved := vsrc.
            pose proof proj1 (Memory.store_some_load_some _ _ saved) Hload as [mem'' Hstore'].
            (* Continue. *)
            exists (StackState C (callers s)).
            eexists. (* evar (CS : state (CS.sem p)). exists CS. *)
            split; [| split].
            + (* Evaluate steps of back-translated event first. *)
              Local Transparent expr_of_const_val loc_of_reg.
              take_steps.
              * exact Hloadmem_vsrc.
              * take_steps; first exact Hstore'.
                (* Do recursive call. *)
                take_steps.
                -- eapply find_procedures_of_trace; eauto; by subst p.
                -- (* Now we are done with the event.
                    We still need to process the external call check. *)
                  take_steps.
                  ++ (* TODO: Needs a new invariant that talks about the init
                       check. Assume for now that it exists, and
                       initialization has already taken place --
                       initial events?. *)
                    instantiate (1 := Int 1).
                    simpl.
                    destruct wf_mem. subst prefix. unfold C in *.
                    rewrite <- Hcomp1. rewrite <- Hcomp1 in C_b.
                    specialize (wfmem0 prefix0 e1 Logic.eq_refl)
                      as [_ [Hpostcond_steady _]].
                    specialize (Hpostcond_steady _ C_b Logic.eq_refl) as [G _].
                    rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hstore');
                      last by destruct dst.
                    rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem);
                      easy.
                  ++ take_steps.
                     ** assert (Hload0 := proj1 (wfmem_extcall wf_mem Hprefix01) _ C_b (Logic.eq_sym Hcomp1)).
                        rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hstore');
                          last (now destruct dst). (* Trivial property of register offsets. *)
                        rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem);
                          last easy.
                        exact Hload0.
                     ** unfold invalidate_metadata.
                        take_steps.
                        apply star_refl.
            + (* Reestablish invariant. *)
              econstructor; try reflexivity; try eassumption.
              { destruct s. exact wb. }
              { destruct wf_stk as [top [bot [Heq [Htop Hbot]]]]; subst stk.
                eexists ({| CS.f_component := C; CS.f_arg := arg; CS.f_cont := Kstop |} :: top).
                exists bot. split; [reflexivity | split; [easy |]].
                elim: (callers s) bot Hbot {Star0 Star1}; trivial.
                move=> a l IH bot [] H1 H2.
                fold well_formed_callers in *.
                split.
                ++ simplify_memory.
                   destruct dst; unfold INITFLAG_offset; simpl; try congruence.
                (* destruct (a == ) eqn:eq; *)
                (*   move: eq => /eqP eq; subst. *)
                (* simplify_memory. *)
                (* ** now destruct Postcond1. *)
                (* ** rewrite -Hmem2'; last congruence. *)
                (*    now simplify_memory. *)
                ++ destruct H2 as [? [? [? [? [? [? [? H2]]]]]]].
                   eexists; eexists; eexists; eexists.
                   repeat split; eauto. }
              (* Reestablish memory well-formedness.
               TODO: Refactor, automate. *)
              { (* destruct wf_mem as [wfmem_counter wfmem_meta wfmem]. *)
                constructor.
                - intros C_ Hcomp.
                  destruct (Nat.eqb_spec C C_) as [Heq | Hneq].
                  + subst C_.
                    pose proof Memory.load_after_store_eq _ _ _ _ Hmem as Hmem0.
                    assert (Hoffsetneq' := not_eq_sym Hoffsetneq).
                    rewrite (Memory.load_after_store_neq _ _ _ _ _ Hoffsetneq' Hstore').
                    assumption.
                  + erewrite Memory.load_after_store_neq;
                      last eassumption;
                      last (injection; contradiction).
                    assert (Hload0 := wfmem_counter wf_mem Hcomp).
                    assert (HCneq : (Permission.data, C, Block.local, 0%Z) <> (Permission.data, C_, Block.local, 0%Z))
                      by (now injection). (* Easy contradiction. *)
                    rewrite <- (Memory.load_after_store_neq _ _ _ _ _ HCneq Hmem) in Hload0.
                    rewrite counter_value_snoc. simpl.
                    move: Hneq => /eqP.
                    case: ifP;
                      last now rewrite Z.add_0_r.
                    move => /eqP => Hcontra => /eqP => Hneq.
                    symmetry in Hcontra. contradiction.
                - intros Hcontra. now destruct prefix.
                - intros pref ev Hprefix.
                  apply rcons_inv in Hprefix as [? ?]; subst pref ev.
                  split.
                  + intros C_ Hcomp Hnext.
                    destruct (Nat.eqb_spec C C_) as [Heq | Hneq].
                    * subst C_.
                      rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hstore');
                        last (injection; destruct dst; discriminate).
                      rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem);
                        last (injection; discriminate).
                      apply (proj1 (wfmem_extcall wf_mem Hprefix01) _ Hcomp).
                      now rewrite Hcomp1.
                    * symmetry in Hnext. contradiction.
                  + intros C_ Hcomp Hnext.
                    destruct (Nat.eqb_spec C C_) as [Heq | Hneq].
                    * subst C_. contradiction.
                    * rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hstore');
                        last (injection; destruct dst; discriminate).
                      rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem);
                        last (injection; discriminate).
                      apply (proj2 (wfmem_extcall wf_mem Hprefix01) _ Hcomp).
                      intro; subst C_.
                      contradiction.
                - intros C_ reg Hcomp.
                  destruct (Nat.eqb_spec C C_) as [Heq | Hneq].
                  + subst C_.
                    destruct (EregisterP reg dst). (* mem -[ptr]-> mem'' *)
                    * subst reg.
                      exists saved. (* exists (Int n). *)
                      erewrite Memory.load_after_store_eq; try reflexivity; eassumption.
                    * erewrite Memory.load_after_store_neq;
                        last eassumption;
                        last (destruct reg; destruct dst; try discriminate; contradiction). (* This kind of reasoning on register offsets can be made into a lemma as well. *)
                      rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem);
                        last (now destruct reg).
                      eapply wfmem_meta; now eauto.
                  + destruct (wfmem_meta wf_mem reg Hcomp) as [v' Hload'].
                    exists v'.
                    erewrite Memory.load_after_store_neq;
                      last eassumption;
                      last (now injection).
                    erewrite Memory.load_after_store_neq;
                      try eassumption.
                    now destruct reg.
                - intro Hcontra. now destruct prefix.
                - intros pref ev Hprefix.
                  apply rcons_inv in Hprefix as [? ?]; subst pref ev.
                  destruct (wfmem wf_mem Hprefix01) as [Hpostreg [Hsteady Hinitial]].
                  (* rename n into n0. *) (* rename v into v0.*)
                  rename Hload into Hload0. (*rename mem' into mem'0.*)
                  rename s0 into mem'. (* Trying to preserve proof script... *)
                  split; [| split].
                  + {
                    subst mem'.
                    intros n off Hoffset.
                    simpl in *.
                    (* subst v prefix. *)
                    unfold postcondition_event_registers in Hpostreg.
                    destruct (Z.eqb_spec (reg_offset dst) off) as [Heq | Hneq].
                    * subst off.
                      assert (dst = reg_to_Ereg n)
                        by (now apply reg_offset_inj in Heq).
                      subst dst.
                      destruct (Hpostreg (Ereg_to_reg src) _ Logic.eq_refl)
                        as [v [v'' [Hloadv [Hshiftv Hgetv'']]]].
                      rewrite reg_to_Ereg_to_reg in Hloadv.
                      setoid_rewrite Hcomp1 in Hloadv.
                      rewrite Hloadmem0_vsrc in Hloadv.
                      injection Hloadv as ?; subst v.
                      eexists. eexists.
                      split; [| split].
                      -- erewrite Memory.load_after_store_eq;
                           last exact Hstore'.
                         reflexivity.
                      -- exact Hshiftv.
                      -- destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                         inversion wf_int_pref' as [| | prefint eint1 eint2 Hsteps Hstep Ht].
                         ++ destruct prefix; discriminate. (* contra *)
                         ++ subst prefix. destruct prefix0 as [| ? [|]]; discriminate. (* contra *)
                         ++ rewrite Hprefix01 in Ht.
                            symmetry in Ht. apply cats2_inv in Ht as [? [? ?]]. subst prefint eint1 eint2.
                            inversion Hstep as [| | | tmp1 tmp2 tmp3 tmp4 tmp5 tmp6 | | | |];
                              subst tmp1 tmp2 tmp3 tmp4 tmp5 tmp6.
                            subst t0.
                            rewrite Ereg_to_reg_to_Ereg Machine.Intermediate.Register.gss.
                            exact Hgetv''.
                    * setoid_rewrite Hcomp1 in Hpostreg.
                      destruct (wfmem_meta wf_mem (reg_to_Ereg n) C_b)
                        as [v' Hload'].
                      rewrite Hoffset in Hload'.
                      destruct (Hpostreg n _ Hoffset)
                        as [v [v'' [Hloadv [Hshiftv Hgetv'']]]].
                      eexists. eexists.
                      split; [| split].
                      -- erewrite Memory.load_after_store_neq;
                           last exact Hstore';
                           last (injection; contradiction).
                         erewrite Memory.load_after_store_neq;
                           last exact Hmem;
                           last (subst off; injection; now destruct n).
                         eassumption.
                      -- eassumption.
                      -- destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                         inversion wf_int_pref' as [| | prefint eint1 eint2 Hsteps Hstep Ht].
                         ++ destruct prefix; discriminate. (* contra *)
                         ++ subst prefix. destruct prefix0 as [| ? [ | ]]; discriminate. (* contra *)
                         ++ rewrite Hprefix01 in Ht.
                            symmetry in Ht. apply cats2_inv in Ht as [? [? ?]]. subst prefint eint1 eint2.
                            inversion Hstep as [| | | tmp1 tmp2 tmp3 tmp4 tmp5 tmp6 | | | |];
                              subst tmp1 tmp2 tmp3 tmp4 tmp5 tmp6.
                            subst t0.
                            rewrite Machine.Intermediate.Register.gso;
                              first exact Hgetv''.
                            destruct n; destruct dst; try discriminate; contradiction.
                  }
                  + intros C' _ ?; subst C'. simpl.
                    specialize (Hsteady _ C_b (Logic.eq_sym Hcomp1))
                      as [Hinitflag [Hlocalbuf [Hsnapshot Hnextblock]]].
                    split; [| split; [| split]].
                    (* The first two sub-goals are near-identical arguments on
                     memory operations. *)
                    * erewrite Memory.load_after_store_neq;
                      last exact Hstore';
                      last (injection; now destruct dst).
                      erewrite Memory.load_after_store_neq;
                        last exact Hmem;
                        last (injection; now destruct dst).
                      exact Hinitflag.
                    * erewrite Memory.load_after_store_neq;
                        last exact Hstore';
                        last (injection; now destruct dst).
                      erewrite Memory.load_after_store_neq;
                        last exact Hmem;
                        last (injection; now destruct dst).
                      exact Hlocalbuf.
                    (* ... *)
                    * intros b Hb. simpl.
                      specialize (Hsnapshot b Hb) as [[cid bid] [Hshift' [Hrename Hrename']]].
                      destruct b as [| b']; first contradiction.
                      rewrite shift_S_Some in Hshift'.
                      injection Hshift' as ? ?; subst cid bid.
                      exists (C, b'). split; [| split].
                      -- rewrite shift_S_Some. reflexivity.
                      -- simpl. intros off v' Hload'.
                         erewrite Memory.load_after_store_neq in Hload';
                           last exact Hstore';
                           last (injection; congruence).
                         erewrite Memory.load_after_store_neq in Hload';
                           last exact Hmem;
                           last (injection; congruence).
                         simpl in Hrename.
                         specialize (Hrename off v' Hload') as [v'' [Hload'' Hrename'']].
                         exists v''. split.
                         ** subst mem'. exact Hload''.
                         ** exact Hrename''.
                      -- simpl. intros off v' Hload'.
                         simpl in Hrename'. subst mem'.
                         specialize (Hrename' off v' Hload') as [v'' [Hload'' Hrename'']].
                         exists v''. split.
                         ++ erewrite Memory.load_after_store_neq;
                              last exact Hstore';
                              last (injection; congruence).
                            erewrite Memory.load_after_store_neq;
                              last exact Hmem;
                              last (injection; congruence).
                            exact Hload''.
                         ++ exact Hrename''.
                    * intros next Hnext.
                      rewrite Hmem' in Hnext.
                      specialize (Hnextblock next Hnext).
                      erewrite Memory.next_block_store_stable;
                        last exact Hstore'.
                      erewrite Memory.next_block_store_stable;
                        last exact Hmem.
                      exact Hnextblock.
                  + intros C' Hcomp Hnext.
                    rewrite <- Hcomp1 in Hnext.
                    specialize (Hinitial _ Hcomp Hnext) as [Hsteady' | Hinitial].
                    * destruct Hsteady' as [Hinitflag [Hlocalbuf Hsteady']].
                      left. split; [| split].
                      -- erewrite Memory.load_after_store_neq;
                           last exact Hstore';
                           last (injection; now destruct dst).
                         erewrite Memory.load_after_store_neq;
                           last exact Hmem;
                           last (injection; now destruct dst).
                         exact Hinitflag.
                      -- erewrite Memory.load_after_store_neq;
                           last exact Hstore';
                           last (injection; now destruct dst).
                         erewrite Memory.load_after_store_neq;
                           last exact Hmem;
                           last (injection; now destruct dst).
                         exact Hlocalbuf.
                      -- destruct Hsteady' as [Hsnapshot Hnextblock].
                         split.
                         ++ intros b Hlocal.
                            specialize (Hsnapshot b Hlocal) as [Cb [Hshift' [Hrename Hrename']]].
                            exists Cb. split; [| split].
                            ** exact Hshift'.
                            ** intros off v' Hload.
                               erewrite Memory.load_after_store_neq in Hload;
                                 last exact Hstore';
                                 last (injection; congruence).
                               erewrite Memory.load_after_store_neq in Hload;
                                 last exact Hmem;
                                 last (injection; congruence).
                               specialize (Hrename off v' Hload) as [v'' [Hload'' Hrename]].
                               exists v''. split.
                               --- subst mem'. assumption.
                               --- congruence.
                            ** intros off v' Hload. subst mem'.
                               specialize (Hrename' off v' Hload) as [v'' [Hload'' Hrename']].
                               exists v''. split.
                               --- erewrite Memory.load_after_store_neq;
                                     last exact Hstore';
                                     last (injection; congruence).
                                   erewrite Memory.load_after_store_neq;
                                     last exact Hmem;
                                     last (injection; congruence).
                                   assumption.
                               --- congruence.
                         ++ (* Same sub-proof on next block as above! *)
                           intros next Hnext'.
                           rewrite Hmem' in Hnext'.
                           specialize (Hnextblock next Hnext').
                           erewrite Memory.next_block_store_stable;
                             last exact Hstore'.
                           erewrite Memory.next_block_store_stable;
                             last exact Hmem.
                           exact Hnextblock.
                    * right.
                      destruct Hinitial as [Hinitflag [Hlocalbuf Hinitial]].
                      split; [| split].
                      -- erewrite Memory.load_after_store_neq;
                           last exact Hstore';
                           last (injection; now destruct dst).
                         erewrite Memory.load_after_store_neq;
                           last exact Hmem;
                           last (injection; discriminate).
                         exact Hinitflag.
                      -- erewrite Memory.load_after_store_neq;
                           last exact Hstore';
                           last (injection; now destruct dst).
                         erewrite Memory.load_after_store_neq;
                           last exact Hmem;
                           last (injection; discriminate).
                         exact Hlocalbuf.
                      -- destruct Hinitial as [[Hprealloc Hnextblock] Hnot_shared].
                         split; [split |].
                         ** destruct Hprealloc
                              as [Cmem [buf [HCmem [Hbuf [Hnextblock' Hprealloc]]]]].
                            exists Cmem, buf.
                            split; [| split; [| split]]; try assumption.
                            rewrite -HCmem.
                            subst mem'. reflexivity.
                         ** destruct Hnextblock as [Cmem [HCmem Hnextblock]].
                            exists Cmem. split; last assumption.
                            rewrite -HCmem. symmetry.
                            transitivity (mem C').
                            --- eapply component_memory_after_store_neq; eauto.
                                intro Hcontra. apply Hnext. rewrite -Hcontra. easy.
                            --- eapply component_memory_after_store_neq; eauto.
                                intro Hcontra. apply Hnext. rewrite -Hcontra. easy.
                         ** by rewrite -cats1 project_non_inform_append /= E0_right Hprefix01 cats1.
                - move=> ptr cid bid off.
                  destruct (Pointer.eq ptr (Permission.data, cur_comp s, Block.local, reg_offset dst)) eqn:eq_ptr;
                    move: eq_ptr =>
                             /Pointer.eqP eq_ptr; subst;
                             [erewrite Memory.load_after_store_eq; eauto; try by []
                             | erewrite Memory.load_after_store_neq; eauto; clear eq_ptr].
                  unfold saved. (* unfold saved. simpl. intros R; inversion R; by []. *)
                  (* destruct Hregs0 as [G1 G2]. *)
                  (* destruct (Machine.register_eqb (Ereg_to_reg src) Machine.R_COM) eqn:eqreg; *)
                  (*   move: eqreg => /Machine.registerP eq_reg. *)
                  (* destruct src; try discriminate. rewrite G2 in Hloadmem0_vsrc. by inversion Hloadmem0_vsrc. *)
                  (* specialize (G1 _ _ eq_reg Logic.eq_refl). *)
                  (* destruct src; try by []; rewrite G1 in Hloadmem0_vsrc; by inversion Hloadmem0_vsrc. *)
                  (* eapply wfmem in wf_mem as [G ?]; last eauto. *)
                  eapply wfmem in wf_mem as [G ?]; last eauto.
                  specialize (G (Ereg_to_reg src) _ Logic.eq_refl) as [v1' [v2' G]].
                  destruct G as [G1 [G2 G3]]. unfold C in *.
                  rewrite reg_to_Ereg_to_reg in G1.
                  rewrite -Hcomp1 G1 in Hloadmem0_vsrc. inversion Hloadmem0_vsrc; subst.
                  destruct vsrc as [| [[[[]]]] |]; try discriminate.
                  rewrite /all_zeros_shift /uniform_shift //=
                          /rename_addr_option /sigma_shifting_wrap_bid_in_addr
                          /sigma_shifting_lefttoright_addr_bid
                          /sigma_shifting_lefttoright_option in G2.
                  destruct i0; try discriminate. simpl in G2. intros R; inversion R; by [].
                  destruct (Pointer.eq ptr (Permission.data, cur_comp s, Block.local, 0%Z)) eqn:eq_ptr;
                    move: eq_ptr =>
                             /Pointer.eqP eq_ptr; subst;
                             [erewrite Memory.load_after_store_eq; eauto; try by []
                             | erewrite Memory.load_after_store_neq; eauto; clear eq_ptr].
                  by eapply wfmem_no_private_ptr; eauto.
              }
            + simpl.
              rewrite project_non_inform_append /=.
              rewrite -> !cats0.
              by inversion Hshift; eauto.

          - (* EBinop *)
            (* Gather a few recurrent assumptions at the top. *)
            rename e into op. rename e0 into reg0. rename e1 into reg1. rename e2 into reg2.
            (* rename s0 into emem. *)
            rename t0 into eregs.
            assert (prefix = [::] \/ exists prefix' e', prefix = prefix' ++ [:: e'])
              as [Hprefix | [prefix0 [e1 Hprefix01]]].
            {
              destruct prefix; first by auto.
              right. rewrite lastI -cats1. by eauto.
            }
            { (* Treat empty case separately. *)
              subst prefix. simpl in *.
              assert (Hmain : C = Component.main).
              { unfold C. rewrite Et /= in wb_trace.
                by move: wb_trace => /andP => [[]] => /eqP. }
              subst C. (* NOTE: Avoid substituting to stay close to the standard proof? *)
              destruct (wfmem_ini wf_mem Logic.eq_refl C_b)
                as [Hregs0 [_ Hmaincomp]].
              specialize (Hmaincomp Hmain)
                as [Hload0init [Hload0local Hsnapshot0]].
              destruct (wfmem_meta wf_mem reg0 C_b) as [v0 Hreg0mem0].
              assert (Hreg0mem := Hreg0mem0).
              erewrite <- Memory.load_after_store_neq in Hreg0mem;
                last exact Hmem;
                last (injection; now destruct reg0).
              destruct (wfmem_meta wf_mem reg1 C_b) as [v1 Hreg1mem0].
              assert (Hreg1mem := Hreg1mem0).
              erewrite <- Memory.load_after_store_neq in Hreg1mem;
                last exact Hmem;
                last (injection; now destruct reg1).
              set (saved := eval_binop (binop_of_Ebinop op) v0 v1).
              (* NOTE: In previous cases, we got to the store by a different route. *)
              destruct (wfmem_meta wf_mem reg2 C_b) as [v2 Hreg2mem0].
              assert (Hreg2mem := Hreg2mem0).
              erewrite <- Memory.load_after_store_neq in Hreg2mem;
                last exact Hmem;
                last (injection; now destruct reg2).
              destruct (Memory.store_after_load _ _ _ saved Hreg2mem) as [mem'' Hstore']. (* "Standard" names here... *)
              assert (Hload0extcall := proj1 (wfmem_extcall_ini wf_mem Logic.eq_refl) _ C_b Hmain).
              exists (EBinop Component.main op reg0 reg1 reg2 s0 eregs).
              exists (StackState Component.main (callers s)).
              eexists. (* evar (CS : state (CS.sem p)). exists CS. *)
              split; [| split].
              { (** star steps *)
                Local Transparent expr_of_const_val loc_of_reg.
                take_steps;
                  first exact Hreg0mem.
                take_steps;
                  first exact Hreg1mem.
                take_steps;
                  first exact Hstore'.
                take_steps; (* Do recursive call. *)
                  [eapply find_procedures_of_trace; eauto; by subst p|].
                (* Done with the event. *)
                take_steps; (* Process external call check. *)
                  first (simplify_memory'; exact Hload0init).
                take_steps;
                  first (simplify_memory'; exact Hload0extcall).
                take_steps.
                apply star_refl.
              }
              { (** well-formed state *)
                econstructor; try reflexivity; try eassumption.
                { destruct s. rewrite -Hmain. exact wb. }
                { destruct wf_stk as [top [bot [Heq [Htop Hbot]]]]; subst stk.
                  eexists ({| CS.f_component := Component.main; CS.f_arg := arg; CS.f_cont := Kstop |} :: top).
                  exists bot. rewrite -Hmain. split; [| split]; [easy | easy |].
                  elim: (callers s) bot Hbot {Star0 Star1}; trivial.
                  move=> a l IH bot [] H1 H2.
                  fold well_formed_callers in *.
                  split.
                  ++ simplify_memory.
                     destruct reg2; unfold INITFLAG_offset; simpl; try congruence.
                  (* destruct (a == ) eqn:eq; *)
                  (*   move: eq => /eqP eq; subst. *)
                  (* simplify_memory. *)
                  (* ** now destruct Postcond1. *)
                  (* ** rewrite -Hmem2'; last congruence. *)
                  (*    now simplify_memory. *)
                  ++ destruct H2 as [? [? [? [? [? [? [? H2]]]]]]].
                     eexists; eexists; eexists; eexists.
                     repeat split; eauto. }
                (* Reestablish memory well-formedness.
                 TODO: Refactor, automate. *)
                { (* destruct wf_mem as [wfmem_counter wfmem_meta wfmem]. *)
                  constructor.
                  - intros C_ Hcomp.
                    destruct (Nat.eqb_spec Component.main C_) as [Heq | Hneq].
                    + subst C_.
                      rewrite -Hmain. (* TODO: Rewrite Hmain earlier, avoid duplication *)
                      by simplify_memory'.
                    + simplify_memory'.
                      assert (Hload0 := wfmem_counter wf_mem Hcomp).
                      rewrite Hload0.
                      rewrite /counter_value /=.
                      move: Hneq => /eqP.
                      case: ifP;
                        last reflexivity.
                      move => /eqP => Hcontra => /eqP => Hneq.
                      rewrite Hcontra in Hneq. congruence.
                  - discriminate.
                  - intros pref ev Hprefix.
                    destruct pref as [| ? [ | ]]; try discriminate.
                    injection Hprefix as ?; subst ev.
                    split.
                    + intros C_ Hcomp Hnext.
                      destruct (Nat.eqb_spec Component.main C_) as [Heq | Hneq].
                      * subst C_.
                        simplify_memory'.
                        apply (proj1 (wfmem_extcall_ini wf_mem Logic.eq_refl) _ Hcomp).
                        congruence.
                      * subst C_. rewrite Hmain in Hneq. contradiction.
                    + intros C_ Hcomp Hnext.
                      destruct (Nat.eqb_spec Component.main C_) as [Heq | Hneq].
                      * subst C_. rewrite Hmain in Hnext. contradiction.
                      * simplify_memory'.
                        apply (proj2 (wfmem_extcall_ini wf_mem Logic.eq_refl) _ Hcomp).
                        intros ?; subst C_. contradiction.
                  - intros C_ reg Hcomp.
                    destruct (postcondition_event_registers_load reg Hregs0)
                      as [v_reg_reg [Hload0reg _]].
                    destruct (Nat.eqb_spec Component.main C_) as [Heq | Hneq].
                    + subst C_.
                      rewrite -Hmain.
                      destruct (EregisterP reg reg2) as [Heq | Hneq].
                      * subst reg2.
                        eexists.
                        by simplify_memory'.
                      * eexists.
                        simplify_memory'.
                        exact Hload0reg.
                    + destruct (wfmem_ini wf_mem Logic.eq_refl Hcomp) as [Hregs0' _].
                      destruct (postcondition_event_registers_load reg Hregs0')
                        as [v_reg_reg' [Hload0reg' _]].
                      eexists.
                      (* assert (Hload0reg' := Hregs0' (Ereg_to_reg reg) _ Logic.eq_refl). *)
                      (* rewrite reg_to_Ereg_to_reg in Hload0reg'. *)
                      simplify_memory'. exact Hload0reg'.
                  - discriminate.
                  - intros pref ev Hprefix.
                    destruct pref as [| ? [ | ]]; try discriminate.
                    injection Hprefix as ?; subst ev.
                    split; [| split].
                    + {
                      intros reg off Hoffset.
                      destruct (wfmem_ini wf_mem Logic.eq_refl C_b) as [Hregs _].
                      destruct (EregisterP (reg_to_Ereg reg) reg2) as [Heq | Hneq].
                      - subst reg2 off.
                        eexists. eexists.
                        split; [| split].
                        + by simplify_memory'.
                        + instantiate (1 := saved).
                          destruct (postcondition_event_registers_load reg0 Hregs0)
                            as [v0' [Hreg0mem0' Hv0]].
                          rewrite Hreg0mem0 in Hreg0mem0'.
                          injection Hreg0mem0' as ?; subst v0'.
                          destruct (postcondition_event_registers_load reg1 Hregs0)
                            as [v1' [Hreg1mem0' Hv1]].
                          rewrite Hreg1mem0 in Hreg1mem0'.
                          injection Hreg1mem0' as ?; subst v1'.
                          unfold saved.
                          Local Transparent binop_of_Ebinop. unfold binop_of_Ebinop. Local Opaque binop_of_Ebinop.
                          destruct v0; destruct Hv0 as [|]; try discriminate;
                            destruct v1; destruct Hv1 as [|]; try discriminate;
                            destruct op;
                            reflexivity.
                        + (* rename t0 into eregs. *)
                          destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                          inversion wf_int_pref' as [eint | eint Hstep Heint | prefint eint1 eint2 Hsteps Hstep Ht];
                            last (destruct prefint as [| ? []]; discriminate).
                          subst eint.
                          inversion Hstep as [| | | | tmp1 tmp2 tmp3 tmp4 tmp5 tmp6 | | |];
                            subst tmp1 tmp2 tmp3 tmp4 tmp5 tmp6;
                            subst eregs.
                          subst er1 er2 er3 s0 saved.
                          simpl.
                          rewrite Ereg_to_reg_to_Ereg Machine.Intermediate.Register.gss.
                          assert (Hv0 : Machine.Intermediate.Register.get
                                          (Ereg_to_reg reg0)
                                          (Machine.Intermediate.Register.set Machine.R_COM (Int 0) Machine.Intermediate.Register.init)
                                        = v0). {
                            destruct (EregisterP reg0 E_R_COM) as [| Hreg].
                            - subst reg0.
                              rewrite (proj2 Hregs) in Hreg0mem0.
                              injection Hreg0mem0 as ?; subst v0.
                              now rewrite Machine.Intermediate.Register.gss.
                            - assert (Hreg' : Ereg_to_reg reg0 <> Machine.R_COM)
                                by (destruct reg0; try discriminate; congruence).
                              rewrite <- (reg_to_Ereg_to_reg reg0) in Hreg0mem0.
                              rewrite ((proj1 Hregs) _ _ Hreg' Logic.eq_refl)
                                in Hreg0mem0.
                              injection Hreg0mem0 as ?; subst v0.
                              rewrite Machine.Intermediate.Register.gso;
                                last exact Hreg'.
                              rewrite /Machine.Intermediate.Register.get
                                      Machine.Intermediate.Register.reg_in_domm_init_Undef; last (apply /dommP; exists Undef; now destruct reg0).
                              by destruct reg0.
                          }
                          assert (Hv1 : Machine.Intermediate.Register.get
                                          (Ereg_to_reg reg1)
                                          (Machine.Intermediate.Register.set Machine.R_COM (Int 0) Machine.Intermediate.Register.init)
                                        = v1). {
                            destruct (EregisterP reg1 E_R_COM) as [| Hreg].
                            - subst reg1.
                              rewrite (proj2 Hregs) in Hreg1mem0.
                              injection Hreg1mem0 as ?; subst v1.
                              now rewrite Machine.Intermediate.Register.gss.
                            - assert (Hreg' : Ereg_to_reg reg1 <> Machine.R_COM)
                                by (destruct reg1; try discriminate; congruence).
                              rewrite <- (reg_to_Ereg_to_reg reg1) in Hreg1mem0.
                              rewrite ((proj1 Hregs) _ _ Hreg' Logic.eq_refl)
                                in Hreg1mem0.
                              injection Hreg1mem0 as ?; subst v1.
                              rewrite Machine.Intermediate.Register.gso;
                                last exact Hreg'.
                              rewrite /Machine.Intermediate.Register.get
                                      Machine.Intermediate.Register.reg_in_domm_init_Undef; last (apply /dommP; exists Undef; now destruct reg1).
                              by destruct reg1.
                          }
                          subst v0 v1.
                          reflexivity.
                      - destruct (postcondition_event_registers_load (reg_to_Ereg reg) Hregs)
                          as [v_reg_reg [Hload0reg Hv_reg_reg]].
                        eexists. eexists.
                        split; [| split].
                        * subst off. simplify_memory.
                          -- injection. by destruct reg.
                          -- injection.
                             move=> /reg_offset_inj => ?; subst reg2;
                                                     contradiction.

                        * destruct Hv_reg_reg as [|]; subst v_reg_reg;
                            reflexivity.
                        * (* rename t0 into eregs. *)
                          destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                          inversion wf_int_pref' as [| eint Hstep Heint | prefint eint1 eint2 Hsteps Hstep Ht];
                            last (destruct prefint as [| ? []]; discriminate).
                          subst eint.
                          inversion Hstep as [| | | | tmp1 tmp2 tmp3 tmp4 tmp5 tmp6 | | |];
                            subst tmp1 tmp2 tmp3 tmp4 tmp5 tmp6;
                            subst eregs.
                          subst er1 er2 er3 s0 saved.
                          simpl.
                          rewrite Machine.Intermediate.Register.gso;
                            last (intros ?; subst reg; now destruct reg2).
                          destruct (Machine.Intermediate.Register.eqP reg Machine.R_COM) as [| Hreg].
                          -- subst reg.
                             rewrite (proj2 Hregs) in Hload0reg.
                             injection Hload0reg as ?; subst v_reg_reg.
                             now rewrite Machine.Intermediate.Register.gss.
                          -- rewrite ((proj1 Hregs) _ _ Hreg Logic.eq_refl)
                               in Hload0reg.
                             injection Hload0reg as ?; subst v_reg_reg.
                             rewrite Machine.Intermediate.Register.gso;
                               last exact Hreg.
                             rewrite /Machine.Intermediate.Register.get
                                     Machine.Intermediate.Register.reg_in_domm_init_Undef; last (apply /dommP; exists Undef; now destruct reg).
                             by destruct reg.
                    }
                    + intros C' _ ?; subst C'. simpl. (* lookup *)
                      (* This is directly needed for the second sub-goal, but also
                     useful for the fourth one. *)
                      destruct (wfmem_ini wf_mem Logic.eq_refl C_b)
                        as [Hregs [_ Hmaincomp]].
                      specialize (Hmaincomp Hmain) as [Hinitflag [Hlocalbuf [Hshift0 Hblock0]]].
                      (* Continue. *)
                      split; [| split; [| split]].
                      * by simplify_memory'.
                      * by simplify_memory'. (* Trivial due to work up front. *)
                      * (* Nothing shared so far *)
                        intros b Hb. simpl.
                        destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                        inversion wf_int_pref' as [| eint Hstep Heint | prefint eint1 eint2 Hsteps Hstep Ht];
                          last (destruct prefint as [| ? []]; discriminate).
                        subst eint.
                        rename s0 into eregs_.
                        inversion Hstep as [| | | | tmp1 tmp2 tmp3 tmp4 tmp5 tmp6 | | |];
                          subst tmp1 tmp2 tmp3 tmp4 tmp5 tmp6;
                          subst eregs.
                        subst er1 er2 er3 eregs_.
                        specialize (Hshift0 _ Hb)
                          as [[cid bid] [Hshift' [Hrename Hrename']]].
                        destruct b as [| b']; first discriminate.
                        rewrite shift_S_Some in Hshift'.
                        injection Hshift' as ? ?; subst cid bid.
                        eexists. split; [| split].
                        -- rewrite shift_S_Some. reflexivity.
                        -- simpl. intros off v' Hload.
                           (* Check next_block_prepare_buffers C_b. *)
                           pose proof Hblock0 _ (next_block_initial_memory C_b)
                             as Hnext0.
                           erewrite Memory.load_after_store_neq in Hload;
                             last eassumption;
                             last (injection; discriminate).
                           erewrite Memory.load_after_store_neq in Hload;
                             last eassumption;
                             last (injection; discriminate).
                           simpl in *.
                           destruct b' as [| b''];
                             last (erewrite Memory.load_next_block_None in Hload;
                                   [ discriminate
                                   | eassumption
                                   | rewrite /LOCALBUF_blockid /=; apply /ssrnat.leP; lia]).
                           simpl.
                           specialize (Hrename _ _ Hload)
                             as [v'' [Hload'' Hrename'']].
                           exists v''.
                           split; assumption.
                        -- simpl. intros off v' Hload.
                           pose proof next_block_initial_memory C_b as Hnext0.
                           destruct b' as [| b''];
                             last (erewrite Memory.load_next_block_None in Hload;
                                   [ discriminate
                                   | eassumption
                                   | rewrite /LOCALBUF_blockid /=; apply /ssrnat.leP; lia]).
                           specialize (Hrename' _ _ Hload)
                             as [v'' [Hload'' Hrename'']].
                           exists v''. split.
                           ++ now simplify_memory'.
                           ++ eassumption.
                      * intros b Hnext'. simpl in Hnext'.
                        destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                        inversion wf_int_pref' as [| eint Hstep Heint | prefint eint1 eint2 Hsteps Hstep Ht];
                          last (destruct prefint as [| ? []]; discriminate).
                        subst eint.
                        rename s0 into eregs_.
                        inversion Hstep as [| | | | tmp1 tmp2 tmp3 tmp4 tmp5 tmp6 | | |];
                          subst tmp1 tmp2 tmp3 tmp4 tmp5 tmp6;
                          subst eregs.
                        subst er1 er2 er3 eregs_.
                        erewrite Memory.next_block_store_stable;
                          last eassumption.
                        erewrite Memory.next_block_store_stable;
                          last eassumption.
                        rewrite /component_buffer in C_b.
                        rewrite /Memory.next_block mkfmapfE C_b in Hnext'.
                        injection Hnext' as Hnext'.
                        rewrite ComponentMemory.nextblock_prealloc in Hnext'.
                        destruct (prog_buffers (cur_comp s)) as [buf |] eqn:Hbuf;
                          last (move: Hbuf => /dommPn;
                                             rewrite -domm_buffers => Hcontra;
                                                                       by rewrite C_b in Hcontra).
                        rewrite domm_set domm0 fsetU0 /= in Hnext'; subst b.
                        exact (Hblock0 _ (next_block_initial_memory C_b)).
                    + intros C' Hcomp Hneq.
                      simpl in Hneq. rewrite Hmain in Hneq. (* Needed for simplify_memory' *)
                      (* rewrite <- Hcomp1 in Hnext. *)
                      destruct (wfmem_ini wf_mem Logic.eq_refl Hcomp)
                        as [Hregs [Hothercomp _]].
                      specialize (Hothercomp Hneq)
                        as [Hinitflag [Hlocalbuf [Hnextblock Hsnapshot]]].
                      (* [Hinitflag [Hlocalbuf [Cmem [HCmem Hnextblock]]]]]. *)
                      right.
                      split; [| split; [| split]].
                      * simplify_memory'. exact Hinitflag.
                      * simplify_memory'. exact Hlocalbuf.
                      (* erewrite Memory.load_after_store_neq; (* TODO: Add to tactic *) *)
                      (*   last exact Hstore4; *)
                      (*   last (fold C; injection; congruence). *)
                      (* simplify_memory'. *)
                      (* exact Hlocalbuf. *)
                      * split.
                        -- destruct (prog_buffers C') as [buf |] eqn:HCbuf;
                             last by (rewrite /component_buffer domm_buffers in Hcomp;
                                      move: HCbuf => /dommPn => Hcontra;
                                                              rewrite Hcomp in Hcontra).
                           eexists. exists buf.
                           split; [| split; [| split]];
                             try reflexivity.
                           ++ destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                              inversion wf_int_pref' as [| eint Hstep Heint | prefint eint1 eint2 Hsteps Hstep Ht];
                                last (destruct prefint as [| ? []]; discriminate).
                              subst eint.
                              rename s0 into eregs_.
                              inversion Hstep as [| | | | tmp1 tmp2 tmp3 tmp4 tmp5 tmp6 | | |];
                                subst tmp1 tmp2 tmp3 tmp4 tmp5 tmp6;
                                subst eregs.
                              subst er1 er2 er3 eregs_.
                              rewrite /initial_memory /= mkfmapfE.
                              unfold component_buffer in Hcomp.
                              by rewrite Hcomp HCbuf //.
                           ++ rewrite ComponentMemory.nextblock_prealloc
                                      domm_set domm0 /=.
                              by rewrite fsetU0.
                        -- destruct (mem0 C') as [Cmem |] eqn:HCmem.
                           ++ exists Cmem. split.
                              ** repeat
                                  ((erewrite <- component_memory_after_store_neq;
                                    [| eassumption | intro Hcontra; subst C'; contradiction])
                                   ||
                                     (erewrite <- component_memory_after_alloc_neq;
                                      [| eassumption | intro Hcontra; subst C'; contradiction])).
                                 exact HCmem.
                              ** rewrite /Memory.next_block HCmem in Hnextblock.
                                 now injection Hnextblock.
                           ++
                             Local Transparent Memory.load. unfold Memory.load in Hinitflag. Local Opaque Memory.load.
                             rewrite /= HCmem in Hinitflag. discriminate.
                      * intros b Hshared.
                        rewrite -!cats1 //= in Hshared.
                        inversion Hshared; now find_nil_rcons.
                  - move=> ptr cid bid off.
                    destruct (Pointer.eq ptr (Permission.data, cur_comp s, Block.local, reg_offset reg2)) eqn:eq_ptr;
                      move: eq_ptr =>
                               /Pointer.eqP eq_ptr; subst;
                               [erewrite Memory.load_after_store_eq; eauto; try by []
                               | erewrite Memory.load_after_store_neq; eauto; clear eq_ptr].
                    unfold saved. (* unfold saved. simpl. intros R; inversion R; by []. *)
                    destruct Hregs0 as [G1 G2].
                    destruct (Machine.register_eqb (Ereg_to_reg reg0) Machine.R_COM) eqn:eqreg;
                      move: eqreg => /Machine.registerP eq_reg.
                    destruct reg0; try discriminate. rewrite G2 in Hreg0mem0.
                    destruct (Machine.register_eqb (Ereg_to_reg reg1) Machine.R_COM) eqn:eqreg';
                      move: eqreg' => /Machine.registerP eq_reg'.
                    destruct reg1; try discriminate. rewrite G2 in Hreg1mem0.
                    inversion Hreg0mem0; inversion Hreg1mem0; subst. by destruct op.
                    specialize (G1 _ _ eq_reg' Logic.eq_refl). rewrite reg_to_Ereg_to_reg in G1.
                    rewrite G1 in Hreg1mem0. by inversion Hreg0mem0; inversion Hreg1mem0; destruct op.
                    specialize (G1 _ _ eq_reg Logic.eq_refl). rewrite reg_to_Ereg_to_reg in G1.
                    rewrite G1 in Hreg0mem0. by inversion Hreg0mem0; destruct op.
                    (* eapply wfmem in wf_mem as [G ?]; last eauto. *)
                    (* specialize (G (Ereg_to_reg src) _ Logic.eq_refl) as [v1' [v2' G]]. *)
                    (* destruct G as [G1 [G2 G3]]. unfold C in *. *)
                    (* rewrite reg_to_Ereg_to_reg in G1. *)
                    (* rewrite -Hcomp1 G1 in Hloadmem0_vsrc. inversion Hloadmem0_vsrc; subst. *)
                    (* destruct vsrc as [| [[[[]]]] |]; try discriminate. *)
                    (* rewrite /all_zeros_shift /uniform_shift //= *)
                    (*         /rename_addr_option /sigma_shifting_wrap_bid_in_addr *)
                    (*         /sigma_shifting_lefttoright_addr_bid *)
                    (*         /sigma_shifting_lefttoright_option in G2. *)
                    (*  destruct i0; try discriminate. simpl in G2. intros R; inversion R; by []. *)
                    destruct (Pointer.eq ptr (Permission.data, cur_comp s, Block.local, 0%Z)) eqn:eq_ptr;
                      move: eq_ptr =>
                               /Pointer.eqP eq_ptr; subst;
                               [erewrite Memory.load_after_store_eq; eauto; try by []
                               | erewrite Memory.load_after_store_neq; eauto; clear eq_ptr].
                    by eapply wfmem_no_private_ptr; eauto.
                }
              }
              {
                destruct prefix' as [| e prefix'].
                - rewrite cats0. now constructor.
                - rewrite lastI in Hshift.
                  inversion Hshift. subst t0 t'.
                  inversion H.
                  + rewrite -lastI in H0. discriminate.
                  + destruct tprefix; discriminate.
              }
            }
            (* destruct (well_formed_memory_store_reg_offset v ptr C_b wf_mem) as [mem' Hstore]. (* TODO: Consider actual utility of this. *) *)
            (* Const does not modify the (shared) memory, therefore these two
             should be identical. *)
            assert (Hmem' : s0 = mem_of_event_inform e1). {
              subst prefix.
              clear -wf_int_pref'.
              move: wf_int_pref'; rewrite !cats1 => [[wf_int_pref _]].
              inversion wf_int_pref.
              - now destruct prefix0.
              - destruct prefix0. inversion H. simpl in H. now destruct prefix0.
              - apply rcons_inj in H. inversion H; subst; clear H.
                apply rcons_inj in H3. inversion H3; subst; clear H3.
                inversion H1; subst; clear H1.
                reflexivity.
            }
            assert (C_next_e1: C = next_comp_of_event e1).
            {
              destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
              rewrite Hprefix01 in wf_ev_comps'.
              setoid_rewrite <- app_assoc in wf_ev_comps'.
              apply trace_event_components_app_r in wf_ev_comps'.
              setoid_rewrite cats1 in wf_ev_comps'.
              inversion wf_ev_comps'. rewrite lastI in H.
              apply rcons_inj in H. inversion H. subst e2. clear H.
              rewrite -cats1 in H3. apply elt_eq_unit in H3 as [? [? _]]. subst e0 t0.
              by rewrite H0.
            }

            assert (Hcomp1 : next_comp_of_event e1 = cur_comp s).
            { by auto. }
            clear C_next_e1.
            (* NOTE: Instantiations! [ptr] seems to have no effect in the proofs. *)
            exists (EBinop C op reg0 reg1 reg2 s0 eregs).
            (* Case analysis on concrete constant expression; all cases are
             similar.
             TODO: Refactoring. *)
            destruct (wfmem_meta wf_mem reg0 C_b) as [v0 Hreg0mem0].
            assert (Hreg0mem := Hreg0mem0).
            erewrite <- Memory.load_after_store_neq in Hreg0mem;
              last exact Hmem;
              last (injection; now destruct reg0).
            destruct (wfmem_meta wf_mem reg1 C_b) as [v1 Hreg1mem0].
            assert (Hreg1mem := Hreg1mem0).
            erewrite <- Memory.load_after_store_neq in Hreg1mem;
              last exact Hmem;
              last (injection; now destruct reg1).
            set (saved := eval_binop (binop_of_Ebinop op) v0 v1).
            (* NOTE: In previous cases, we got to the store by a different route. *)
            destruct (wfmem_meta wf_mem reg2 C_b) as [v2 Hreg2mem0].
            assert (Hreg2mem := Hreg2mem0).
            erewrite <- Memory.load_after_store_neq in Hreg2mem;
              last exact Hmem;
              last (injection; now destruct reg2).
            destruct (Memory.store_after_load _ _ _ saved Hreg2mem) as [mem'' Hstore']. (* "Standard" names here... *)
            (* Continue. *)
            exists (StackState C (callers s)).
            eexists. (* evar (CS : state (CS.sem p)). exists CS. *)
            split; [| split].
            + (* Evaluate steps of back-translated event first. *)
              Local Transparent expr_of_const_val loc_of_reg.
              take_steps.
              * exact Hreg0mem.
              * take_steps.
                -- exact Hreg1mem.
                -- take_steps.
                   ++ exact Hstore'.
                   ++ (* Do recursive call. *)
                     take_steps.
                     ** eapply find_procedures_of_trace; eauto; by subst p.
                     ** (* Now we are done with the event.
                          We still need to process the external call check. *)
                       take_steps.
                       --- destruct (wfmem wf_mem Hprefix01) as [_ [Hsteady _]].
                           specialize (Hsteady _ C_b (Logic.eq_sym Hcomp1)) as [Hoffset _].
                           erewrite Memory.load_after_store_neq;
                             last exact Hstore';
                             last (injection; now destruct reg2).
                           erewrite Memory.load_after_store_neq;
                             last exact Hmem;
                             last (injection; now destruct reg2).
                           exact Hoffset.
                       --- take_steps.
                           +++ assert (Hload0 := proj1 (wfmem_extcall wf_mem Hprefix01) _ C_b (Logic.eq_sym Hcomp1)).
                               rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hstore');
                                 last (now destruct reg2). (* Trivial property of register offsets. *)
                               rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem);
                                 last easy.
                               exact Hload0.
                           +++ unfold invalidate_metadata.
                               take_steps.
                               apply star_refl.
            + (* Reestablish invariant. *)
              econstructor; try reflexivity; try eassumption.
              { destruct s. exact wb. }
              { destruct wf_stk as [top [bot [Heq [Htop Hbot]]]]; subst stk.
                eexists ({| CS.f_component := C; CS.f_arg := arg; CS.f_cont := Kstop |} :: top).
                exists bot. split; [reflexivity| split; [easy |]].
                elim: (callers s) bot Hbot {Star0 Star1}; trivial.
                move=> a l IH bot [] H1 H2.
                fold well_formed_callers in *.
                split.
                ++ simplify_memory.
                   destruct reg2; unfold INITFLAG_offset; simpl; try congruence.
                (* destruct (a == ) eqn:eq; *)
                (*   move: eq => /eqP eq; subst. *)
                (* simplify_memory. *)
                (* ** now destruct Postcond1. *)
                (* ** rewrite -Hmem2'; last congruence. *)
                (*    now simplify_memory. *)
                ++ destruct H2 as [? [? [? [? [? [? [? H2]]]]]]].
                   eexists; eexists; eexists; eexists.
                   repeat split; eauto. }
              (* Reestablish memory well-formedness.
               TODO: Refactor, automate. *)
              { (* destruct wf_mem as [wfmem_counter wfmem_meta wfmem]. *)
                (* instantiate (1 := mem). (* FIXME *) *)
                constructor.
                - intros C_ Hcomp.
                  destruct (Nat.eqb_spec C C_) as [Heq | Hneq].
                  + subst C_.
                    pose proof Memory.load_after_store_eq _ _ _ _ Hmem as Hmem0.
                    assert (Hoffsetneq' : (Permission.data, C, Block.local, reg_offset reg2) <> (Permission.data, C, Block.local, 0%Z))
                      by (now destruct reg2).
                    rewrite (Memory.load_after_store_neq _ _ _ _ _ Hoffsetneq' Hstore').
                    assumption.
                  + erewrite Memory.load_after_store_neq;
                      last eassumption;
                      last (injection; contradiction).
                    assert (Hload0 := wfmem_counter wf_mem Hcomp).
                    assert (HCneq : (Permission.data, C, Block.local, 0%Z) <> (Permission.data, C_, Block.local, 0%Z))
                      by (now injection). (* Easy contradiction. *)
                    rewrite <- (Memory.load_after_store_neq _ _ _ _ _ HCneq Hmem) in Hload0.
                    rewrite counter_value_snoc. simpl.
                    move: Hneq => /eqP.
                    case: ifP;
                      last now rewrite Z.add_0_r.
                    move => /eqP => Hcontra => /eqP => Hneq.
                    symmetry in Hcontra. contradiction.
                - intros Hcontra. now destruct prefix.
                - intros pref ev Hprefix.
                  apply rcons_inv in Hprefix as [? ?]; subst pref ev.
                  split.
                  + intros C_ Hcomp Hnext.
                    destruct (Nat.eqb_spec C C_) as [Heq | Hneq].
                    * subst C_.
                      rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hstore');
                        last (injection; destruct reg2; discriminate).
                      rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem);
                        last (injection; discriminate).
                      apply (proj1 (wfmem_extcall wf_mem Hprefix01) _ Hcomp).
                      now rewrite Hcomp1.
                    * symmetry in Hnext. contradiction.
                  + intros C_ Hcomp Hnext.
                    destruct (Nat.eqb_spec C C_) as [Heq | Hneq].
                    * subst C_. contradiction.
                    * rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hstore');
                        last (injection; destruct reg2; discriminate).
                      rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem);
                        last (injection; discriminate).
                      apply (proj2 (wfmem_extcall wf_mem Hprefix01) _ Hcomp).
                      intro; subst C_.
                      contradiction.
                - intros C_ reg Hcomp.
                  destruct (Nat.eqb_spec C C_) as [Heq | Hneq].
                  + subst C_.
                    destruct (EregisterP reg reg2).
                    * subst reg2.
                      (* exists (Int n). *)
                      exists saved.
                      erewrite Memory.load_after_store_eq; try reflexivity; eassumption.
                    * erewrite Memory.load_after_store_neq;
                        last eassumption;
                        last (destruct reg; destruct reg2; try discriminate; contradiction). (* This kind of reasoning on register offsets can be made into a lemma as well. *)
                      rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem);
                        last (now destruct reg).
                      eapply wfmem_meta; now eauto.
                  + destruct (wfmem_meta wf_mem reg Hcomp) as [v' Hload'].
                    exists v'.
                    erewrite Memory.load_after_store_neq;
                      last eassumption;
                      last (now injection).
                    erewrite Memory.load_after_store_neq;
                      try eassumption.
                    now destruct reg.
                - intro Hcontra. now destruct prefix.
                - intros pref ev Hprefix.
                  apply rcons_inv in Hprefix as [? ?]; subst pref ev.
                  destruct (wfmem wf_mem Hprefix01) as [Hregs [Hsteady Hinitial]].
                  (* rename n into n0. rename v into v0. rename Hload into Hload0. rename mem' into mem'0. *) rename s0 into mem'. (* Trying to preserve proof script... *)
                  split; [| split].
                  + {
                    subst mem'.
                    intros n off Hoffset.
                    simpl in *.
                    unfold postcondition_event_registers in Hregs.
                    destruct (Z.eqb_spec (reg_offset reg2) off) as [Heq | Hneq].
                    * subst off.
                      assert (reg2 = reg_to_Ereg n)
                        by (now apply reg_offset_inj in Heq).
                      subst reg2.

                      Ltac t_postcondition_event_registers_get
                           prefix prefix0 Hprefix01 eregs :=
                        inversion wf_int_pref' as [| | prefint eint1 eint2 Hsteps Hstep Ht];
                        [ destruct prefix; discriminate (* contra *)
                        | subst prefix; destruct prefix0 as [| ? [|]]; discriminate (* contra *)
                        | rewrite Hprefix01 in Ht;
                          symmetry in Ht; apply cats2_inv in Ht as [? [? ?]]; subst prefint eint1 eint2;
                          inversion Hstep as [| | | | tmp1 tmp2 tmp3 tmp4 tmp5 tmp6 | | |];
                          subst tmp1 tmp2 tmp3 tmp4 tmp5 tmp6;
                          subst eregs;
                          [rewrite Ereg_to_reg_to_Ereg Machine.Intermediate.Register.gss]].
                      (* reflexivity]. *)

                      rewrite <- Hcomp1 in Hreg0mem0.
                      destruct (Hregs (Ereg_to_reg reg0) _ (f_equal _ (reg_to_Ereg_to_reg _)))
                        as [vs0 [vs0' [Hload0 [Hshift0 Hget0]]]].
                      rewrite <- Hcomp1 in Hreg1mem0.
                      destruct (Hregs (Ereg_to_reg reg1) _ (f_equal _ (reg_to_Ereg_to_reg _)))
                        as [vs1 [vs1' [Hload1 [Hshift1 Hget1]]]].
                      rewrite Hreg0mem0 in Hload0. injection Hload0 as ?; subst vs0.
                      rewrite Hreg1mem0 in Hload1. injection Hload1 as ?; subst vs1.
                      destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].

                      Local Transparent binop_of_Ebinop. (* TODO: This was made locally opaque earlier but not reversed! *)

                      Ltac t_postcondition_event_registers_binop_case
                           mem prefix prefix0 Hprefix01 eregs Hstore' Hget0 Hget1 Hshift0 Hshift1 vs0' vs1' :=
                        repeat match goal with
                               | Hload : Memory.load mem _ = Some (Ptr (Permission.data, _, ?B, _)),
                                   HBsub : context [ ssrnat.subn_rec 1 ?B ] |- _ =>
                                   destruct B as [| ?];
                                   [discriminate |];
                                   simpl in HBsub
                               end;
                        [eexists; eexists];
                        split; [| split];
                        [ erewrite Memory.load_after_store_eq; [reflexivity | exact Hstore']
                        | reflexivity
                        |];
                        t_postcondition_event_registers_get prefix prefix0 Hprefix01 eregs;
                        rewrite Hget0 Hget1;
                        injection Hshift0 as ?; subst vs0';
                        injection Hshift1 as ?; subst vs1';
                        reflexivity.

                      Ltac t_postcondition_event_registers_data_pointers mem :=
                        repeat match goal with
                               | Hload : Memory.load mem _ = Some (Ptr (Permission.data, _, ?B, _)),
                                   HBsub : context [ ssrnat.subn_rec 1 ?B ] |- _ =>
                                   destruct B as [| ?];
                                   [discriminate |];
                                   simpl in HBsub
                               end.

                      Ltac t_postcondition_event_registers_pointer_Cb
                           Hstore' HeqC Heqb prefix prefix0 Hprefix01 eregs Hget0 Hget1 Hshift0 Hshift1 vs0' vs1' HeqC Heqb :=
                        eexists; eexists;
                        [split; [| split]];
                        [ erewrite Memory.load_after_store_eq; [reflexivity | exact Hstore']
                        | rewrite /= HeqC Heqb //
                        |];
                        simpl;
                        t_postcondition_event_registers_get prefix prefix0 Hprefix01 eregs;
                        rewrite Hget0 Hget1;
                        injection Hshift0 as ?; subst vs0';
                        injection Hshift1 as ?; subst vs1';
                        unfold ssrnat.addn, ssrnat.subn, ssrnat.addn_rec, ssrnat.subn_rec,
                          all_zeros_shift, uniform_shift;
                        simpl;
                        rewrite !Nat.add_0_r !Nat.sub_0_r HeqC Heqb;
                        reflexivity.

                      Ltac t_postcondition_event_registers_pointer_Cbo
                           Hstore' prefix prefix0 Hprefix01 eregs Hget0 Hget1 Hshift0 Hshift1 vs0' vs1' HeqC Heqb Heqo :=
                        eexists; eexists;
                        [split; [| split]];
                        [ erewrite Memory.load_after_store_eq; [reflexivity | exact Hstore']
                        | rewrite /= HeqC Heqb Heqo //=
                        |];
                        t_postcondition_event_registers_get prefix prefix0 Hprefix01 eregs;
                        rewrite Hget0 Hget1;
                        injection Hshift0 as ?; subst vs0';
                        injection Hshift1 as ?; subst vs1';
                        unfold ssrnat.addn, ssrnat.subn, ssrnat.addn_rec, ssrnat.subn_rec,
                          all_zeros_shift, uniform_shift;
                        simpl;
                        rewrite !Nat.add_0_r !Nat.sub_0_r HeqC Heqb Heqo;
                        reflexivity.

                      Ltac t_postcondition_event_registers_code_pointer_Cb
                           Hstore' HeqC Heqb prefix prefix0 Hprefix01 eregs Hget0 Hget1 Hshift0 Hshift1 vs0' vs1' HeqC Heqb :=
                        eexists; eexists;
                        [split; [| split]];
                        [ erewrite Memory.load_after_store_eq; [reflexivity | exact Hstore']
                        | rewrite /= HeqC Heqb //
                        |];
                        simpl;
                        t_postcondition_event_registers_get prefix prefix0 Hprefix01 eregs;
                        rewrite Hget0 Hget1;
                        injection Hshift0 as ?; subst vs0';
                        injection Hshift1 as ?; subst vs1';
                        unfold ssrnat.addn, ssrnat.subn, ssrnat.addn_rec, ssrnat.subn_rec,
                          all_zeros_shift, uniform_shift;
                        simpl;
                        rewrite HeqC Heqb;
                        reflexivity.

                      (* General case analysis on values and operations. Most
                           cases can be solved from this information alone. *)
                      unfold shift_value_option,
                        rename_value_option,
                        rename_value_template_option,
                        rename_addr_option,
                        sigma_shifting_wrap_bid_in_addr,
                        sigma_shifting_lefttoright_addr_bid,
                        sigma_shifting_lefttoright_option in *.
                      unfold ssrnat.leq, ssrnat.addn, ssrnat.subn,
                        all_zeros_shift, uniform_shift in *.
                      unfold saved in *.
                      simpl.
                      destruct v0 as [n0 | [[[[] C0] b0] o0] |];
                        destruct v1 as [n1 | [[[[] C1] b1] o1] |];
                        destruct op;
                        simpl;
                        (* t_postcondition_event_registers_shift_pointers. *)
                        try t_postcondition_event_registers_binop_case
                            mem prefix prefix0 Hprefix01 eregs Hstore' Hget0 Hget1 Hshift0 Hshift1 vs0' vs1'.

                      (* In a few cases, more interesting pointer operations
                           are required. Note that this amount of case analysis
                           is overkill in the sense that one false check
                           suffices to short-circuit evaluation (and similar
                           optimizations may be possible above). *)
                      -- simpl;
                         destruct (C0 =? C1) eqn:HeqC;
                         destruct (b0 =? b1) eqn:Heqb;
                         t_postcondition_event_registers_code_pointer_Cb
                           Hstore' HeqC Heqb prefix prefix0 Hprefix01 eregs Hget0 Hget1 Hshift0 Hshift1 vs0' vs1' HeqC Heqb.

                      -- simpl;
                           destruct (C0 =? C1) eqn:HeqC;
                           destruct (b0 =? b1) eqn:Heqb;
                           t_postcondition_event_registers_code_pointer_Cb
                             Hstore' HeqC Heqb prefix prefix0 Hprefix01 eregs Hget0 Hget1 Hshift0 Hshift1 vs0' vs1' HeqC Heqb.

                      -- t_postcondition_event_registers_data_pointers mem;
                           simpl;
                           destruct (C0 =? C1) eqn:HeqC;
                           destruct (b0 =? b1) eqn:Heqb;
                           t_postcondition_event_registers_pointer_Cb
                             Hstore' HeqC Heqb prefix prefix0 Hprefix01 eregs Hget0 Hget1 Hshift0 Hshift1 vs0' vs1' HeqC Heqb.

                      -- t_postcondition_event_registers_data_pointers mem;
                           simpl;
                           destruct (C0 =? C1) eqn:HeqC;
                           destruct (b0 =? b1) eqn:Heqb;
                           t_postcondition_event_registers_pointer_Cb
                             Hstore' HeqC Heqb prefix prefix0 Hprefix01 eregs Hget0 Hget1 Hshift0 Hshift1 vs0' vs1' HeqC Heqb.

                      -- t_postcondition_event_registers_data_pointers mem;
                           simpl;
                           destruct (C0 =? C1) eqn:HeqC;
                           destruct (b0 =? b1) eqn:Heqb;
                           destruct (o0 <=? o1)%Z eqn:Heqo;
                           t_postcondition_event_registers_pointer_Cbo
                             Hstore' prefix prefix0 Hprefix01 eregs Hget0 Hget1 Hshift0 Hshift1 vs0' vs1' HeqC Heqb Heqo.

                    * setoid_rewrite Hcomp1 in Hregs.
                      destruct (wfmem_meta wf_mem (reg_to_Ereg n) C_b)
                        as [v' Hload'].
                      rewrite Hoffset in Hload'.
                      destruct (Hregs n _ Logic.eq_refl) as [v [v'' [Hload [Hshift' Hget']]]].
                      assert (v = v'). {
                        subst off. rewrite Hload' in Hload. now injection Hload.
                      }
                      subst v'.
                      eexists. eexists.
                      split; [| split].
                      -- erewrite Memory.load_after_store_neq;
                           last exact Hstore';
                           last (subst off; injection; now destruct n).
                         erewrite Memory.load_after_store_neq;
                           last exact Hmem;
                           last (subst off; injection; now destruct n).
                         exact Hload'.
                      -- eassumption.
                      -- destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                         inversion wf_int_pref' as [| | prefint eint1 eint2 Hsteps Hstep Ht].
                         ++ destruct prefix; discriminate. (* contra *)
                         ++ subst prefix. destruct prefix0 as [| ? [ | ]]; discriminate. (* contra *)
                         ++ rewrite Hprefix01 in Ht.
                            symmetry in Ht. apply cats2_inv in Ht as [? [? ?]]. subst prefint eint1 eint2.
                            inversion Hstep as [| | | | tmp1 tmp2 tmp3 tmp4 tmp5 tmp6 | | |];
                              subst tmp1 tmp2 tmp3 tmp4 tmp5 tmp6.
                            subst eregs.
                            rewrite Machine.Intermediate.Register.gso;
                              first exact Hget'.
                            destruct n; destruct reg2; try discriminate; contradiction.
                  }
                  + intros C' _ ?; subst C'. simpl.
                    specialize (Hsteady _ C_b (Logic.eq_sym Hcomp1))
                      as [Hinitflag [Hlocalbuf [Hsnapshot Hnextblock]]].
                    split; [| split; [| split]].
                    (* The first two sub-goals are near-identical arguments on
                     memory operations. *)
                    * erewrite Memory.load_after_store_neq;
                      last exact Hstore';
                      last (injection; now destruct reg2).
                      erewrite Memory.load_after_store_neq;
                        last exact Hmem;
                        last (injection; now destruct reg2).
                      exact Hinitflag.
                    * erewrite Memory.load_after_store_neq;
                        last exact Hstore';
                        last (injection; now destruct reg2).
                      erewrite Memory.load_after_store_neq;
                        last exact Hmem;
                        last (injection; now destruct reg2).
                      exact Hlocalbuf.
                    (* ... *)
                    * intros b Hb. simpl.
                      specialize (Hsnapshot b Hb) as [[cid bid] [Hshift' [Hrename Hrename']]].
                      destruct b as [| b']; first discriminate.
                      rewrite shift_S_Some in Hshift'.
                      injection Hshift' as ? ?; subst cid bid.
                      exists (C, b'). split; [| split].
                      -- rewrite shift_S_Some. reflexivity.
                      -- simpl. intros off v' Hload'.
                         erewrite Memory.load_after_store_neq in Hload';
                           last exact Hstore';
                           last (injection; congruence).
                         erewrite Memory.load_after_store_neq in Hload';
                           last exact Hmem;
                           last (injection; congruence).
                         simpl in Hrename.
                         specialize (Hrename off v' Hload') as [v'' [Hload'' Hrename'']].
                         exists v''. split.
                         ++ subst mem'. exact Hload''.
                         ++ exact Hrename''.
                      -- simpl. intros off v' Hload'.
                         simpl in Hrename'. subst mem'.
                         specialize (Hrename' off v' Hload') as [v'' [Hload'' Hrename'']].
                         exists v''. split.
                         ++ erewrite Memory.load_after_store_neq;
                              last exact Hstore';
                              last (injection; congruence).
                            erewrite Memory.load_after_store_neq;
                              last exact Hmem;
                              last (injection; congruence).
                            exact Hload''.
                         ++ exact Hrename''.
                    * intros next Hnext.
                      rewrite Hmem' in Hnext.
                      specialize (Hnextblock next Hnext).
                      erewrite Memory.next_block_store_stable;
                        last exact Hstore'.
                      erewrite Memory.next_block_store_stable;
                        last exact Hmem.
                      exact Hnextblock.
                  + intros C' Hcomp Hnext.
                    rewrite <- Hcomp1 in Hnext.
                    specialize (Hinitial _ Hcomp Hnext) as [Hsteady' | Hinitial].
                    * destruct Hsteady' as [Hinitflag [Hlocalbuf Hsteady']].
                      left. split; [| split].
                      -- erewrite Memory.load_after_store_neq;
                           last exact Hstore';
                           last (injection; now destruct reg2).
                         erewrite Memory.load_after_store_neq;
                           last exact Hmem;
                           last (injection; now destruct reg2).
                         exact Hinitflag.
                      -- erewrite Memory.load_after_store_neq;
                           last exact Hstore';
                           last (injection; now destruct reg2).
                         erewrite Memory.load_after_store_neq;
                           last exact Hmem;
                           last (injection; now destruct reg2).
                         exact Hlocalbuf.
                      -- destruct Hsteady' as [Hsnapshot Hnextblock].
                         split.
                         ++ intros b Hlocal.
                            specialize (Hsnapshot b Hlocal) as [Cb [Hshift' [Hrename Hrename']]].
                            exists Cb. split; [| split].
                            ** exact Hshift'.
                            ** intros off v' Hload.
                               erewrite Memory.load_after_store_neq in Hload;
                                 last exact Hstore';
                                 last (injection; congruence).
                               erewrite Memory.load_after_store_neq in Hload;
                                 last exact Hmem;
                                 last (injection; congruence).
                               specialize (Hrename off v' Hload) as [v'' [Hload'' Hrename]].
                               exists v''. split.
                               --- subst mem'. assumption.
                               --- congruence.
                            ** intros off v' Hload. subst mem'.
                               specialize (Hrename' off v' Hload) as [v'' [Hload'' Hrename']].
                               exists v''. split.
                               --- erewrite Memory.load_after_store_neq;
                                     last exact Hstore';
                                     last (injection; congruence).
                                   erewrite Memory.load_after_store_neq;
                                     last exact Hmem;
                                     last (injection; congruence).
                                   assumption.
                               --- congruence.
                         ++ (* Same sub-proof on next block as above! *)
                           intros next Hnext'.
                           rewrite Hmem' in Hnext'.
                           specialize (Hnextblock next Hnext').
                           erewrite Memory.next_block_store_stable;
                             last exact Hstore'.
                           erewrite Memory.next_block_store_stable;
                             last exact Hmem.
                           exact Hnextblock.
                    * right.
                      destruct Hinitial as [Hinitflag [Hlocalbuf Hinitial]].
                      split; [| split].
                      -- erewrite Memory.load_after_store_neq;
                           last exact Hstore';
                           last (injection; now destruct reg2).
                         erewrite Memory.load_after_store_neq;
                           last exact Hmem;
                           last (injection; discriminate).
                         exact Hinitflag.
                      -- erewrite Memory.load_after_store_neq;
                           last exact Hstore';
                           last (injection; now destruct reg2).
                         erewrite Memory.load_after_store_neq;
                           last exact Hmem;
                           last (injection; discriminate).
                         exact Hlocalbuf.
                      -- destruct Hinitial as [[Hprealloc Hnextblock] Hnot_shared].
                         split; [split |].
                         ** destruct Hprealloc
                              as [Cmem [buf [HCmem [Hbuf [Hnextblock' Hprealloc]]]]].
                            exists Cmem, buf.
                            split; [| split; [| split]]; try assumption.
                            rewrite -HCmem.
                            subst mem'. reflexivity.
                         ** destruct Hnextblock as [Cmem [HCmem Hnextblock]].
                            exists Cmem. split; last assumption.
                            rewrite -HCmem. symmetry.
                            transitivity (mem C').
                            --- eapply component_memory_after_store_neq; eauto.
                                intro Hcontra. apply Hnext. rewrite -Hcontra. easy.
                            --- eapply component_memory_after_store_neq; eauto.
                                intro Hcontra. apply Hnext. rewrite -Hcontra. easy.
                         ** by rewrite -cats1 project_non_inform_append /= E0_right Hprefix01 cats1.
                - move=> ptr cid bid off.
                  destruct (Pointer.eq ptr (Permission.data, cur_comp s, Block.local, reg_offset reg2)) eqn:eq_ptr;
                    move: eq_ptr =>
                             /Pointer.eqP eq_ptr; subst;
                             [erewrite Memory.load_after_store_eq; eauto; try by []
                             | erewrite Memory.load_after_store_neq; eauto; clear eq_ptr].
                  eapply wfmem in wf_mem as [G ?]; last eauto.
                  assert (G' := G).
                  specialize (G (Ereg_to_reg reg0) _ Logic.eq_refl) as [v1' [v2' G]].
                  destruct G as [G1 [G2 G3]]. unfold C in *.
                  specialize (G' (Ereg_to_reg reg1) _ Logic.eq_refl) as [v1'' [v2'' G']].
                  destruct G' as [G1' [G2' G3']]. unfold C in *.
                  rewrite reg_to_Ereg_to_reg in G1.
                  rewrite reg_to_Ereg_to_reg in G1'.
                  rewrite -Hcomp1 G1 in Hreg0mem0. inversion Hreg0mem0; subst.
                  rewrite -Hcomp1 G1' in Hreg1mem0. inversion Hreg1mem0; subst.
                  destruct v0 as [| [[[[]]]] |]; try discriminate;
                    destruct v1 as [| [[[[]]]] |]; try discriminate;
                    (* destruct vsrc as [| [[[[]]]] |]; try discriminate. *)
                    rewrite /all_zeros_shift /uniform_shift //=
                            /rename_addr_option /sigma_shifting_wrap_bid_in_addr
                            /sigma_shifting_lefttoright_addr_bid
                            /sigma_shifting_lefttoright_option in G2;
                    rewrite /all_zeros_shift /uniform_shift //=
                            /rename_addr_option /sigma_shifting_wrap_bid_in_addr
                            /sigma_shifting_lefttoright_addr_bid
                            /sigma_shifting_lefttoright_option in G2';
                    unfold saved; try (by destruct op; intros R; inversion R; by []).
                  destruct i0; try discriminate. simpl in G2. destruct op; intros R; inversion R; by [].
                  destruct op; intros R; inversion R. move: H1; by case: ifP.
                  move: H1; by case: ifP.
                  destruct i0; try discriminate. simpl in G2. destruct op; intros R; inversion R; by [].
                  destruct op; intros R; inversion R. move: H1; by case: ifP.
                  move: H1; by case: ifP.
                  destruct (Pointer.eq ptr (Permission.data, cur_comp s, Block.local, 0%Z)) eqn:eq_ptr;
                    move: eq_ptr =>
                             /Pointer.eqP eq_ptr; subst;
                             [erewrite Memory.load_after_store_eq; eauto; try by []
                             | erewrite Memory.load_after_store_neq; eauto; clear eq_ptr].
                  by eapply wfmem_no_private_ptr; eauto.
              }
            + simpl.
              rewrite project_non_inform_append /=.
              rewrite -> !cats0.
              by inversion Hshift; eauto.

          - (* ELoad *)
            (* Gather a few recurrent assumptions at the top. *)
            rename e into reg0. rename e0 into reg1. rename t0 into eregs.
            assert (prefix = [::] \/ exists prefix' e', prefix = prefix' ++ [:: e'])
              as [Hprefix | [prefix0 [e1 Hprefix01]]].
            {
              destruct prefix; first by auto.
              right. rewrite lastI -cats1. by eauto.
            }
            { (* Treat empty case separately. *)
              exfalso. (* Nothing to do in the load case. *)
              subst prefix. simpl in *.
              (* NOTE: This should come from well-formedness of events. *)
              destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
              inversion wf_int_pref';
                last now destruct prefix as [|? []].
              subst e.
              inversion H0. subst regs mem1 C0 er1 er2 s0 regs'.
              destruct (Machine.Intermediate.Register.eqP (Ereg_to_reg reg0) Machine.R_COM) as [Heq | Hneq].
              - rewrite Heq Machine.Intermediate.Register.gss in H5.
                discriminate.
              - rewrite Machine.Intermediate.Register.gso in H5;
                  last exact Hneq.
                rewrite /Machine.Intermediate.Register.get
                        Machine.Intermediate.Register.reg_in_domm_init_Undef in H5;
                  last (apply /dommP; exists Undef; now destruct reg0).
                by destruct reg0.
            }
            (* destruct (well_formed_memory_store_reg_offset v ptr C_b wf_mem) as [mem' Hstore]. (* TODO: Consider actual utility of this. *) *)
            (* Const does not modify the (shared) memory, therefore these two
             should be identical. *)
            assert (Hmem' : s0 = mem_of_event_inform e1). {
              subst prefix.
              clear -wf_int_pref'.
              move: wf_int_pref'; rewrite !cats1 => [[wf_int_pref _]].
              inversion wf_int_pref.
              - now destruct prefix0.
              - destruct prefix0. inversion H. simpl in H. now destruct prefix0.
              - apply rcons_inj in H. inversion H; subst; clear H.
                apply rcons_inj in H3. inversion H3; subst; clear H3.
                inversion H1; subst; clear H1.
                reflexivity.
            }
            assert (C_next_e1: C = next_comp_of_event e1).
            {
              destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
              rewrite Hprefix01 in wf_ev_comps'.
              setoid_rewrite <- app_assoc in wf_ev_comps'.
              apply trace_event_components_app_r in wf_ev_comps'.
              setoid_rewrite cats1 in wf_ev_comps'.
              inversion wf_ev_comps'. rewrite lastI in H.
              apply rcons_inj in H. inversion H. subst e2. clear H.
              rewrite -cats1 in H3. apply elt_eq_unit in H3 as [? [? _]]. subst e0 t0.
              by rewrite H0.
            }

            assert (Hcomp1 : next_comp_of_event e1 = cur_comp s).
            { by auto. }
            clear C_next_e1.
            (* NOTE: Instantiations! [ptr] seems to have no effect in the proofs. *)
            exists (ELoad C reg0 reg1 s0 eregs).
            destruct (wfmem_meta wf_mem reg0 C_b) as [v0 Hreg0mem0].
            assert (exists C0 b0' o0, v0 = Ptr (Permission.data, C0, S b0', o0))
              as [C0 [b0' [o0 ?]]]. {
              destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
              inversion wf_int_pref' as [| | prefint eint1 eint2 Hsteps Hstep Ht];
                [ destruct prefix; discriminate (* contra *)
                | subst prefix; destruct prefix0 as [| ? [|]]; discriminate (* contra *)
                | rewrite Hprefix01 in Ht;
                  symmetry in Ht; apply cats2_inv in Ht as [? [? ?]]; subst prefint eint1 eint2;
                  inversion Hstep as [| | | | | tmp1 tmp2 tmp3 tmp4 tmp5 tmp6 | |];
                  subst tmp1 tmp2 tmp3 tmp4 tmp5 tmp6;
                  subst eregs].
              destruct ptr as [[[[] C'] b'] o'];
                first discriminate. (* Contra on load *)
              destruct (wfmem wf_mem Hprefix01) as [Hregs [Hsteady Hinitial]].
              destruct (Hregs (Ereg_to_reg reg0) _ Logic.eq_refl)
                as [v0'' [v0' [Hload0 [Hshift0 Hget0]]]].
              rewrite H in Hget0. subst v0'.
              rewrite reg_to_Ereg_to_reg in Hload0.
              rewrite Hcomp1 Hreg0mem0 in Hload0.
              injection Hload0 as ?; subst v0''.
              destruct v0 as [| [[[[] C0] [| b0']] o0] |]; try discriminate.
              rewrite /= /ssrnat.addn /ssrnat.addn_rec
                      /ssrnat.subn /ssrnat.subn_rec
                      /all_zeros_shift /uniform_shift
                      /= Nat.add_0_r Nat.sub_0_r in Hshift0.
              injection Hshift0 as ? ? ?; subst C' b' o'.
              now eauto.
            }
            subst v0.
            assert (Hreg0mem := Hreg0mem0).
            erewrite <- Memory.load_after_store_neq in Hreg0mem;
              last exact Hmem;
              last (injection; now destruct reg0).
            destruct (wfmem_meta wf_mem reg1 C_b) as [v1 Hreg1mem0].
            assert (Hreg1mem := Hreg1mem0).
            erewrite <- Memory.load_after_store_neq in Hreg1mem;
              last exact Hmem;
              last (injection; now destruct reg1).
            (* set (saved := v1). *)
            (* NOTE: In previous cases, we got to the store by a different route. *)
            assert (exists v, Memory.load mem (Permission.data, C0, S b0', o0) = Some v) as [vptr0 Hptr0mem].
            {
              destruct (wfmem wf_mem Hprefix01) as [Hregs [Hsteady Hinitial]].
              destruct (Hregs (Ereg_to_reg reg0) _ Logic.eq_refl) as [v0'' [v0 [Hload0 [Hshift0 Hget0]]]].
              rewrite reg_to_Ereg_to_reg Hcomp1 Hreg0mem0 in Hload0.
              injection Hload0 as ?; subst v0''.
              rewrite /= /ssrnat.addn /ssrnat.addn_rec /ssrnat.subn /ssrnat.subn_rec
                      /= Nat.add_0_r Nat.sub_0_r in Hshift0.
              injection Hshift0 as ?; subst v0.
              destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
              inversion wf_int_pref' as [| | prefint eint1 eint2 Hsteps Hstep Ht];
                [ destruct prefix; discriminate (* contra *)
                | subst prefix; destruct prefix0 as [| ? [|]]; discriminate (* contra *)
                | rewrite Hprefix01 in Ht;
                  symmetry in Ht; apply cats2_inv in Ht as [? [? ?]]; subst prefint eint1 eint2;
                  inversion Hstep as [| | | | | tmp1 tmp2 tmp3 tmp4 tmp5 tmp6 | |];
                  subst tmp1 tmp2 tmp3 tmp4 tmp5 tmp6;
                  subst eregs].
              rewrite -H in H0.
              injection H0 as ?; subst ptr.
              destruct (Nat.eqb_spec C C0) as [| Hneq].
              - subst C0.
                destruct (Hsteady _ C_b (Logic.eq_sym Hcomp1))
                  as [Hinitflag0 [Hlocalbuf [Hshift0 Hblock0]]].
                destruct (Hshift0 (S b0') (Nat.neq_succ_0 _))
                  as [[cid bid] [Hshift0' [Hrename0 Hrename0']]].
                rewrite shift_S_Some in Hshift0'.
                injection Hshift0' as ? ?; subst cid bid.
                destruct (Hrename0' _ _ H1) as [v' [Hload' Hshift']].
                eexists. simplify_memory'. exact Hload'.
              - assert (C0_b : component_buffer C0).
                {
                  unfold component_buffer.
                  change C0 with (Pointer.component (Permission.data, C0, S b0', o0)).
                  (* change intf with (Source.prog_interface p). *)
                  assert (Hrewr: intf = Source.prog_interface p).
                  { by subst p. }
                  rewrite Hrewr. clear Hrewr.                                                
                  eapply CS.load_component_prog_interface; try exact Star0; eauto.
                  -
                    {
                      eapply well_formed_events_well_formed_program
                      in wf_events as [theprog [Hrewr ?]]; eauto.
                      + erewrite Hprog_of_trace in Hrewr. inversion Hrewr.
                        by subst theprog.
                      + by eapply domm_t_procs_exported_procedures_of_trace.
                    }
                  - eapply closed_program_of_trace; by eauto.
                  - reflexivity.
                }
                unfold C in Hneq.
                rewrite <- Hcomp1 in Hneq.
                specialize (Hinitial _ C0_b (nesym Hneq))
                  as [Hsteady0 | Hinitial0].
                * (* This is identical to the C = C0 case above. *)
                  destruct Hsteady0
                    as [Hinitflag0 [Hlocalbuf [Hshift0 Hblock0]]].
                  destruct (Hshift0 (S b0') (Nat.neq_succ_0 _))
                    as [[cid bid] [Hshift0' [Hrename0 Hrename0']]].
                  rewrite shift_S_Some in Hshift0'.
                  injection Hshift0' as ? ?; subst cid bid.
                  simpl in *.
                  destruct (Hrename0' _ _ H1) as [v' [Hload' Hshift']].
                  eexists. simplify_memory'. exact Hload'.
                * (* Contradiction on uninitialized C0. *)
                  destruct Hinitial0
                    as [Hinitflag0 [Hlocalbuf0 [Hsnapshot0 Hnot_shared]]].
                  destruct Hsnapshot0
                    as [[Cmem0 [buf0 [HCmem0 [Hbuf0 [Hnext0 Hprealloc0]]]]]
                          [Cmem0' [HCmem0' Hblock0']]].
                  subst Cmem0.
                  assert (wf_p : Source.well_formed_program p).
                  {
                    eapply well_formed_events_well_formed_program
                      in wf_events as [theprog [Hrewr ?]]; eauto.
                    + erewrite Hprog_of_trace in Hrewr. inversion Hrewr.
                      by subst theprog.
                    + by eapply domm_t_procs_exported_procedures_of_trace.
                  }
                  assert (Hclosed_: Source.closed_program p).
                  { by eapply closed_program_of_trace; eauto. }
                  destruct (CS.load_data_next_block
                              wf_p Hclosed_ Logic.eq_refl
                              Star0 Hreg0mem0)
                    as [Cmem0'' [HCmem0'' Hcontra]].
                  rewrite HCmem0' in HCmem0''.
                  injection HCmem0'' as ?; subst Cmem0''.
                  rewrite Hblock0' /LOCALBUF_blockid in Hcontra. lia.
            }
            destruct (Memory.store_after_load _ _ _ vptr0 Hreg1mem) as [mem'' Hstore']. (* "Standard" names here... *)
            (* Continue. *)
            exists (StackState C (callers s)).
            eexists. (* evar (CS : state (CS.sem p)). exists CS. *)
            split; [| split].
            + (* Evaluate steps of back-translated event first. *)
              Local Transparent expr_of_const_val loc_of_reg.
              take_steps.
              * exact Hreg0mem.
              * (* NOTE: Is it possible to do case analysis on [v0] here? *)
                take_steps.
                -- exact Hptr0mem.
                -- take_steps.
                   ++ exact Hstore'.
                   ++ (* Do recursive call. *)
                     take_steps.
                     ** eapply find_procedures_of_trace; by subst; eauto.
                     ** (* Now we are done with the event.
                          We still need to process the external call check. *)
                       take_steps.
                       --- destruct (wfmem wf_mem Hprefix01) as [_ [Hsteady _]].
                           specialize (Hsteady _ C_b (Logic.eq_sym Hcomp1)) as [Hoffset _].
                           erewrite Memory.load_after_store_neq;
                             last exact Hstore';
                             last (injection; now destruct reg1).
                           erewrite Memory.load_after_store_neq;
                             last exact Hmem;
                             last (injection; now destruct reg1).
                           exact Hoffset.
                       --- take_steps.
                           +++ assert (Hload0 := proj1 (wfmem_extcall wf_mem Hprefix01) _ C_b (Logic.eq_sym Hcomp1)).
                               rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hstore');
                                 last (now destruct reg1). (* Trivial property of register offsets. *)
                               rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem);
                                 last easy.
                               exact Hload0.
                           +++ unfold invalidate_metadata.
                               take_steps.
                               apply star_refl.
            + (* Reestablish invariant. *)
              econstructor; try reflexivity; try eassumption.
              { rewrite Et. by subst. }
              { destruct s. exact wb. }
              { destruct wf_stk as [top [bot [Heq [Htop Hbot]]]]; subst stk.
                eexists ({| CS.f_component := C; CS.f_arg := arg; CS.f_cont := Kstop |} :: top).
                exists bot. split; [reflexivity| split; [easy |]].
                elim: (callers s) bot Hbot {Star0 Star1}; trivial.
                move=> a l IH bot [] H1 H2.
                fold well_formed_callers in *.
                split.
                ++ simplify_memory.
                   destruct reg1; unfold INITFLAG_offset; simpl; try congruence.
                (* destruct (a == ) eqn:eq; *)
                (*   move: eq => /eqP eq; subst. *)
                (* simplify_memory. *)
                (* ** now destruct Postcond1. *)
                (* ** rewrite -Hmem2'; last congruence. *)
                (*    now simplify_memory. *)
                ++ destruct H2 as [? [? [? [? [? [? [? H2]]]]]]].
                   eexists; eexists; eexists; eexists.
                   repeat split; eauto. }
              (* Reestablish memory well-formedness.
               TODO: Refactor, automate. *)
              { (* destruct wf_mem as [wfmem_counter wfmem_meta wfmem]. *)
                constructor.
                - intros C_ Hcomp.
                  destruct (Nat.eqb_spec C C_) as [Heq | Hneq].
                  + subst C_.
                    pose proof Memory.load_after_store_eq _ _ _ _ Hmem as Hmem0.
                    assert (Hoffsetneq' : (Permission.data, C, Block.local, reg_offset reg1) <> (Permission.data, C, Block.local, 0%Z))
                      by (now destruct reg1).
                    rewrite (Memory.load_after_store_neq _ _ _ _ _ Hoffsetneq' Hstore').
                    assumption.
                  + erewrite Memory.load_after_store_neq;
                      last eassumption;
                      last (injection; contradiction).
                    assert (Hload0 := wfmem_counter wf_mem Hcomp).
                    assert (HCneq : (Permission.data, C, Block.local, 0%Z) <> (Permission.data, C_, Block.local, 0%Z))
                      by (now injection). (* Easy contradiction. *)
                    rewrite <- (Memory.load_after_store_neq _ _ _ _ _ HCneq Hmem) in Hload0.
                    rewrite counter_value_snoc. simpl.
                    move: Hneq => /eqP.
                    case: ifP;
                      last now rewrite Z.add_0_r.
                    move => /eqP => Hcontra => /eqP => Hneq.
                    symmetry in Hcontra. contradiction.
                - intros Hcontra. now destruct prefix.
                - intros pref ev Hprefix.
                  apply rcons_inv in Hprefix as [? ?]; subst pref ev.
                  split.
                  + intros C_ Hcomp Hnext.
                    destruct (Nat.eqb_spec C C_) as [Heq | Hneq].
                    * subst C_.
                      rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hstore');
                        last (injection; destruct reg1; discriminate).
                      rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem);
                        last (injection; discriminate).
                      apply (proj1 (wfmem_extcall wf_mem Hprefix01) _ Hcomp).
                      now rewrite Hcomp1.
                    * symmetry in Hnext. contradiction.
                  + intros C_ Hcomp Hnext.
                    destruct (Nat.eqb_spec C C_) as [Heq | Hneq].
                    * subst C_. contradiction.
                    * rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hstore');
                        last (injection; destruct reg1; discriminate).
                      rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem);
                        last (injection; discriminate).
                      apply (proj2 (wfmem_extcall wf_mem Hprefix01) _ Hcomp).
                      intro; subst C_.
                      contradiction.
                - intros C_ reg Hcomp.
                  destruct (Nat.eqb_spec C C_) as [Heq | Hneq].
                  + subst C_.
                    destruct (EregisterP reg reg1).
                    * subst reg1.
                      exists vptr0.
                      erewrite Memory.load_after_store_eq; try reflexivity; eassumption.
                    * erewrite Memory.load_after_store_neq;
                        last eassumption;
                        last (destruct reg; destruct reg1; try discriminate; contradiction). (* This kind of reasoning on register offsets can be made into a lemma as well. *)
                      rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem);
                        last (now destruct reg).
                      eapply wfmem_meta; now eauto.
                  + destruct (wfmem_meta wf_mem reg Hcomp) as [v' Hload'].
                    exists v'.
                    erewrite Memory.load_after_store_neq;
                      last eassumption;
                      last (now injection).
                    erewrite Memory.load_after_store_neq;
                      try eassumption.
                    now destruct reg.
                - intro Hcontra. now destruct prefix.
                - intros pref ev Hprefix.
                  apply rcons_inv in Hprefix as [? ?]; subst pref ev.
                  destruct (wfmem wf_mem Hprefix01) as [Hregs [Hsteady Hinitial]].
                  (* rename n into n0. rename v into v0. rename Hload into Hload0. rename mem' into mem'0. *) rename s0 into mem'. (* Trying to preserve proof script... *)
                  split; [| split].
                  + {
                    (* NOTE: We need to have the snapshot at hand, which is not
                       the case with the rearranged invariants. This can be
                       improved; compare also with [Hsnapshot0] later in this
                       same proof. *)
                    specialize (Hsteady _ C_b (Logic.eq_sym Hcomp1))
                    as [_ [_ [Hsnapshot _]]].
                    (* Standard proof *)
                    subst mem'.
                    intros n off Hoffset.
                    simpl in *.
                    (* subst v prefix. *)
                    unfold postcondition_event_registers in Hregs.
                    destruct (Z.eqb_spec (reg_offset reg1) off) as [Heq | Hneq].
                    - subst off.
                      assert (reg1 = reg_to_Ereg n)
                        by (now apply reg_offset_inj in Heq).
                      subst reg1.
                      (* assert (v = vptr0). { *)
                      (*   rewrite (Memory.load_after_store_eq _ _ _ _ Hstore') in Hload. *)
                      (*   now injection Hload as ?. } *)
                      (* subst v. *)
                      destruct (Nat.eqb_spec C C0) as [| HC0neq].
                      + subst C0.
                        specialize (Hsnapshot _ (Nat.neq_succ_0 b0'))
                          as [[cid bid] [Hshift' [Hrename Hrename']]].
                        injection Hshift' as Hcid Hbid.
                        rewrite /ssrnat.addn /ssrnat.addn_rec /ssrnat.subn /ssrnat.subn_rec
                                /all_zeros_shift /uniform_shift /= Nat.add_0_r Nat.sub_0_r
                          in Hbid.
                        subst cid bid.
                        simpl in *.
                        assert (Hptr0mem0 := Hptr0mem).
                        erewrite Memory.load_after_store_neq in Hptr0mem0;
                          last exact Hmem;
                          last (injection; discriminate).
                        destruct (Hrename _ _ Hptr0mem0) as [v' [Hload' Hshift']].
                        eexists. eexists. split; [| split].
                        * erewrite Memory.load_after_store_eq;
                            [reflexivity | exact Hstore'].
                        * exact Hshift'.
                        * destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                          inversion wf_int_pref' as [| | prefint eint1 eint2 Hsteps Hstep Ht];
                            [ destruct prefix; discriminate (* contra *)
                            | subst prefix; destruct prefix0 as [| ? [|]]; discriminate (* contra *)
                            | rewrite Hprefix01 in Ht;
                              symmetry in Ht; apply cats2_inv in Ht as [? [? ?]]; subst prefint eint1 eint2;
                              inversion Hstep as [| | | | | tmp1 tmp2 tmp3 tmp4 tmp5 tmp6 | |];
                              subst tmp1 tmp2 tmp3 tmp4 tmp5 tmp6;
                              subst eregs].
                          rewrite Ereg_to_reg_to_Ereg Machine.Intermediate.Register.gss.
                          rewrite <- Hcomp1 in Hreg0mem0.
                          destruct (Hregs (Ereg_to_reg reg0) _ (f_equal _ (reg_to_Ereg_to_reg _)))
                            as [vtmp [v'' [Hload'' [Hshift'' Hget'']]]].
                          simpl in *.
                          rewrite Hreg0mem0 in Hload''. injection Hload'' as ?; subst vtmp.
                          rewrite /= /ssrnat.addn /ssrnat.addn_rec /ssrnat.subn /ssrnat.subn_rec
                                  /= Nat.add_0_r Nat.sub_0_r
                            in Hshift''.
                          injection Hshift'' as ?; subst v''.
                          rewrite <- H1 in H.
                          injection H as ?; subst ptr.
                          rewrite H0 in Hload'.
                          now injection Hload'.
                      + assert (C0_b : component_buffer C0).
                        {
                          unfold component_buffer.
                          change C0 with (Pointer.component (Permission.data, C0, S b0', o0)).
                          (* change intf with (Source.prog_interface p). *)
                          assert (Hrewr: intf = Source.prog_interface p).
                          { by subst p. }
                          rewrite Hrewr. clear Hrewr.                                                
                          eapply CS.load_component_prog_interface; try exact Star0; eauto.
                          -
                            {
                              eapply well_formed_events_well_formed_program
                              in wf_events as [theprog [Hrewr ?]]; eauto.
                              + erewrite Hprog_of_trace in Hrewr. inversion Hrewr.
                                by subst theprog.
                              + by eapply domm_t_procs_exported_procedures_of_trace.
                            }
                          - eapply closed_program_of_trace; by eauto.
                          - reflexivity.
                        }
                        unfold C in HC0neq.
                        rewrite <- Hcomp1 in HC0neq.
                        specialize (Hinitial _ C0_b (nesym HC0neq))
                          as [Hsteady | Hinitial].
                        * (* This is identical to the C = C0 case above. *)
                          destruct Hsteady
                            as [Hinitflag0 [Hlocalbuf0 [Hsnapshot0 Hnextblock0]]].
                          specialize (Hsnapshot0 _ (Nat.neq_succ_0 b0'))
                            as [[cid bid] [Hshift' [Hrename Hrename']]].
                          injection Hshift' as Hcid Hbid.
                          rewrite /ssrnat.addn /ssrnat.addn_rec /ssrnat.subn /ssrnat.subn_rec
                                  /all_zeros_shift /uniform_shift /= Nat.add_0_r Nat.sub_0_r
                            in Hbid.
                          subst cid bid.
                          simpl in *.
                          assert (Hptr0mem0 := Hptr0mem).
                          erewrite Memory.load_after_store_neq in Hptr0mem0;
                            last exact Hmem;
                            last (injection; discriminate).
                          destruct (Hrename _ _ Hptr0mem0) as [v' [Hload' Hshift']].
                          eexists. eexists. split; [| split].
                          -- erewrite Memory.load_after_store_eq;
                               [reflexivity | exact Hstore'].
                          -- exact Hshift'.
                          -- destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                             inversion wf_int_pref' as [| | prefint eint1 eint2 Hsteps Hstep Ht];
                               [ destruct prefix; discriminate (* contra *)
                               | subst prefix; destruct prefix0 as [| ? [|]]; discriminate (* contra *)
                               | rewrite Hprefix01 in Ht;
                                 symmetry in Ht; apply cats2_inv in Ht as [? [? ?]]; subst prefint eint1 eint2;
                                 inversion Hstep as [| | | | | tmp1 tmp2 tmp3 tmp4 tmp5 tmp6 | |];
                                 subst tmp1 tmp2 tmp3 tmp4 tmp5 tmp6;
                                 subst eregs].
                             rewrite Ereg_to_reg_to_Ereg Machine.Intermediate.Register.gss.
                             rewrite <- Hcomp1 in Hreg0mem0.
                             destruct (Hregs (Ereg_to_reg reg0) _ (f_equal _ (reg_to_Ereg_to_reg _)))
                               as [vtmp [v'' [Hload'' [Hshift'' Hget'']]]].
                             simpl in *.
                             rewrite Hreg0mem0 in Hload''. injection Hload'' as ?; subst vtmp.
                             rewrite /= /ssrnat.addn /ssrnat.addn_rec /ssrnat.subn /ssrnat.subn_rec
                                     /= Nat.add_0_r Nat.sub_0_r
                               in Hshift''.
                             injection Hshift'' as ?; subst v''.
                             rewrite <- H1 in H.
                             injection H as ?; subst ptr.
                             rewrite H0 in Hload'.
                             now injection Hload'.
                        * (* Contradiction on uninitialized C0, from which
                               nothing could have been shared. *)
                          destruct Hinitial
                            as [Hinitflag0 [Hlocalbuf0 [Hsnapshot0 Hnot_shared0]]].
                          destruct Hsnapshot0
                            as [[Cmem0 [buf0 [HCmem0 [Hbuf0 [Hnext0 Hprealloc0]]]]]
                                  [Cmem0' [HCmem0' Hblock0']]].
                          subst Cmem0.
                          assert (Hptr0mem0 := Hptr0mem).
                          erewrite Memory.load_after_store_neq in Hptr0mem0;
                            last exact Hmem;
                            last (injection; discriminate).
                          Local Transparent Memory.load.
                          unfold Memory.load in Hptr0mem0.
                          Local Opaque Memory.load.
                          rewrite HCmem0' /= in Hptr0mem0.
                          apply ComponentMemory.load_next_block in Hptr0mem0.
                          rewrite Hblock0' in Hptr0mem0.
                          discriminate.
                    - setoid_rewrite Hcomp1 in Hregs.
                      destruct (wfmem_meta wf_mem (reg_to_Ereg n) C_b)
                        as [v' Hload'].
                      rewrite Hoffset in Hload'.
                      destruct (Hregs n _ Logic.eq_refl) as [v [v'' [Hload [Hshift' Hget']]]].
                      assert (v = v'). {
                        subst off. rewrite Hload' in Hload. now injection Hload.
                      }
                      subst v'.
                      eexists. eexists.
                      split; [| split].
                      -- erewrite Memory.load_after_store_neq;
                           last exact Hstore';
                           last (subst off; injection; now destruct n).
                         erewrite Memory.load_after_store_neq;
                           last exact Hmem;
                           last (subst off; injection; now destruct n).
                         exact Hload'.
                      -- eassumption.
                      -- destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                         inversion wf_int_pref' as [| | prefint eint1 eint2 Hsteps Hstep Ht].
                         ++ destruct prefix; discriminate. (* contra *)
                         ++ subst prefix. destruct prefix0 as [| ? [ | ]]; discriminate. (* contra *)
                         ++ rewrite Hprefix01 in Ht.
                            symmetry in Ht. apply cats2_inv in Ht as [? [? ?]]. subst prefint eint1 eint2.
                            inversion Hstep as [| | | | | tmp1 tmp2 tmp3 tmp4 tmp5 tmp6 | |];
                              subst tmp1 tmp2 tmp3 tmp4 tmp5 tmp6.
                            subst eregs.
                            rewrite Machine.Intermediate.Register.gso;
                              first exact Hget'.
                            destruct n; destruct reg1; try discriminate; contradiction.
                  }
                  + intros C' _ ?; subst C'. simpl.
                    specialize (Hsteady _ C_b (Logic.eq_sym Hcomp1))
                      as [Hinitflag [Hlocalbuf [Hsnapshot Hnextblock]]].
                    split; [| split; [| split]].
                    (* The first two sub-goals are near-identical arguments on
                     memory operations. *)
                    * erewrite Memory.load_after_store_neq;
                      last exact Hstore';
                      last (injection; now destruct reg1).
                      erewrite Memory.load_after_store_neq;
                        last exact Hmem;
                        last (injection; now destruct reg1).
                      exact Hinitflag.
                    * erewrite Memory.load_after_store_neq;
                        last exact Hstore';
                        last (injection; now destruct reg1).
                      erewrite Memory.load_after_store_neq;
                        last exact Hmem;
                        last (injection; now destruct reg1).
                      exact Hlocalbuf.
                    (* ... *)
                    * intros b Hb. simpl.
                      specialize (Hsnapshot b Hb) as [[cid bid] [Hshift' [Hrename Hrename']]].
                      destruct b as [| b']; first contradiction.
                      rewrite shift_S_Some in Hshift'.
                      injection Hshift' as ? ?; subst cid bid.
                      exists (C, b'). split; [| split].
                      -- rewrite shift_S_Some. reflexivity.
                      -- simpl. intros off v' Hload'.
                         erewrite Memory.load_after_store_neq in Hload';
                           last exact Hstore';
                           last (injection; congruence).
                         erewrite Memory.load_after_store_neq in Hload';
                           last exact Hmem;
                           last (injection; congruence).
                         simpl in Hrename.
                         specialize (Hrename off v' Hload') as [v'' [Hload'' Hrename'']].
                         exists v''. split.
                         ++ subst mem'. exact Hload''.
                         ++ exact Hrename''.
                      -- simpl. intros off v' Hload'.
                         simpl in Hrename'. subst mem'.
                         specialize (Hrename' off v' Hload') as [v'' [Hload'' Hrename'']].
                         exists v''. split.
                         ++ erewrite Memory.load_after_store_neq;
                              last exact Hstore';
                              last (injection; congruence).
                            erewrite Memory.load_after_store_neq;
                              last exact Hmem;
                              last (injection; congruence).
                            exact Hload''.
                         ++ exact Hrename''.
                    * intros next Hnext.
                      rewrite Hmem' in Hnext.
                      specialize (Hnextblock next Hnext).
                      erewrite Memory.next_block_store_stable;
                        last exact Hstore'.
                      erewrite Memory.next_block_store_stable;
                        last exact Hmem.
                      exact Hnextblock.
                  + intros C' Hcomp Hnext.
                    rewrite <- Hcomp1 in Hnext.
                    specialize (Hinitial _ Hcomp Hnext) as [Hsteady' | Hinitial].
                    * destruct Hsteady' as [Hinitflag [Hlocalbuf Hsteady']].
                      left. split; [| split].
                      -- erewrite Memory.load_after_store_neq;
                           last exact Hstore';
                           last (injection; now destruct reg1).
                         erewrite Memory.load_after_store_neq;
                           last exact Hmem;
                           last (injection; now destruct reg1).
                         exact Hinitflag.
                      -- erewrite Memory.load_after_store_neq;
                           last exact Hstore';
                           last (injection; now destruct reg1).
                         erewrite Memory.load_after_store_neq;
                           last exact Hmem;
                           last (injection; now destruct reg1).
                         exact Hlocalbuf.
                      -- destruct Hsteady' as [Hsnapshot Hnextblock].
                         split.
                         ++ intros b Hlocal.
                            specialize (Hsnapshot b Hlocal) as [Cb [Hshift' [Hrename Hrename']]].
                            exists Cb. split; [| split].
                            ** exact Hshift'.
                            ** intros off v' Hload.
                               erewrite Memory.load_after_store_neq in Hload;
                                 last exact Hstore';
                                 last (injection; congruence).
                               erewrite Memory.load_after_store_neq in Hload;
                                 last exact Hmem;
                                 last (injection; congruence).
                               specialize (Hrename off v' Hload) as [v'' [Hload'' Hrename]].
                               exists v''. split.
                               --- subst mem'. assumption.
                               --- congruence.
                            ** intros off v' Hload. subst mem'.
                               specialize (Hrename' off v' Hload) as [v'' [Hload'' Hrename']].
                               exists v''. split.
                               --- erewrite Memory.load_after_store_neq;
                                     last exact Hstore';
                                     last (injection; congruence).
                                   erewrite Memory.load_after_store_neq;
                                     last exact Hmem;
                                     last (injection; congruence).
                                   assumption.
                               --- congruence.
                         ++ (* Same sub-proof on next block as above! *)
                           intros next Hnext'.
                           rewrite Hmem' in Hnext'.
                           specialize (Hnextblock next Hnext').
                           erewrite Memory.next_block_store_stable;
                             last exact Hstore'.
                           erewrite Memory.next_block_store_stable;
                             last exact Hmem.
                           exact Hnextblock.
                    * right.
                      destruct Hinitial as [Hinitflag [Hlocalbuf [Hinitial Hnot_shared]]].
                      split; [| split; [| split]].
                      -- erewrite Memory.load_after_store_neq;
                           last exact Hstore';
                           last (injection; now destruct reg1).
                         erewrite Memory.load_after_store_neq;
                           last exact Hmem;
                           last (injection; discriminate).
                         exact Hinitflag.
                      -- erewrite Memory.load_after_store_neq;
                           last exact Hstore';
                           last (injection; now destruct reg1).
                         erewrite Memory.load_after_store_neq;
                           last exact Hmem;
                           last (injection; discriminate).
                         exact Hlocalbuf.
                      -- destruct Hinitial as [Hprealloc Hnextblock].
                         split.
                         ** destruct Hprealloc
                              as [Cmem [buf [HCmem [Hbuf [Hnextblock' Hprealloc]]]]].
                            exists Cmem, buf.
                            split; [| split; [| split]]; try assumption.
                            rewrite -HCmem.
                            subst mem'. reflexivity.
                         ** destruct Hnextblock as [Cmem [HCmem Hnextblock]].
                            exists Cmem. split; last assumption.
                            rewrite -HCmem. symmetry.
                            transitivity (mem C').
                            --- eapply component_memory_after_store_neq; eauto.
                                intro Hcontra. apply Hnext. rewrite -Hcontra. easy.
                            --- eapply component_memory_after_store_neq; eauto.
                                intro Hcontra. apply Hnext. rewrite -Hcontra. easy.
                      -- by rewrite -cats1 project_non_inform_append /= E0_right Hprefix01 cats1.
                - move=> ptr cid bid off.
                  destruct (Pointer.eq ptr (Permission.data, cur_comp s, Block.local, reg_offset reg1)) eqn:eq_ptr;
                    move: eq_ptr =>
                             /Pointer.eqP eq_ptr; subst;
                             [erewrite Memory.load_after_store_eq; eauto; try by []
                             | erewrite Memory.load_after_store_neq; eauto; clear eq_ptr].
                  erewrite Memory.load_after_store_neq in Hptr0mem; eauto.
                  intros R. inversion R; subst.
                  by eapply wfmem_no_private_ptr in Hptr0mem; eauto.
                  unfold Block.local; congruence.
                  destruct (Pointer.eq ptr (Permission.data, cur_comp s, Block.local, 0%Z)) eqn:eq_ptr;
                    move: eq_ptr =>
                             /Pointer.eqP eq_ptr; subst;
                             [erewrite Memory.load_after_store_eq; eauto; try by []
                             | erewrite Memory.load_after_store_neq; eauto; clear eq_ptr].
                  by eapply wfmem_no_private_ptr; eauto.
              }
            + simpl.
              rewrite project_non_inform_append /=.
              rewrite -> !cats0.
              by inversion Hshift; eauto.

          - (* EStore *)
            rename e into reg0. rename e0 into reg1.
            (* rename s0 into emem. *)
            rename t0 into eregs.
            assert (prefix = [::] \/ exists prefix' e', prefix = prefix' ++ [:: e'])
              as [Hprefix | [prefix0 [e1 Hprefix01]]].
            {
              destruct prefix; first by auto.
              right. rewrite lastI -cats1. by eauto.
            }
            { (* Treat empty case separately. *)
              exfalso. (* Nothing to do in the store case. *)
              subst prefix. simpl in *.
              (* NOTE: This should come from well-formedness of events. *)
              destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
              inversion wf_int_pref';
                last now destruct prefix as [|? []].
              subst e.
              inversion H0. subst regs mem1 C0 er1 er2 mem' eregs.
              destruct (Machine.Intermediate.Register.eqP (Ereg_to_reg reg0) Machine.R_COM) as [Heq | Hneq].
              - rewrite Heq Machine.Intermediate.Register.gss in H4.
                discriminate.
              - rewrite Machine.Intermediate.Register.gso in H4;
                  last exact Hneq.
                rewrite /Machine.Intermediate.Register.get
                        Machine.Intermediate.Register.reg_in_domm_init_Undef in H4; last (apply /dommP; exists Undef; now destruct reg0).
                by destruct reg0.
            }
            (* Relate memories before and after store. *)
            assert (exists ptr,
                       Machine.Intermediate.Register.get (Ereg_to_reg reg0) (register_file_of_event_inform e1) = Ptr ptr /\
                         Memory.store (mem_of_event_inform e1) ptr (Machine.Intermediate.Register.get (Ereg_to_reg reg1) (register_file_of_event_inform e1)) = Some s0)
              as [ptr [Hgetptr Hstore]]. {
              subst prefix.
              clear -wf_int_pref'.
              move: wf_int_pref'; rewrite !cats1 => [[wf_int_pref _]].
              inversion wf_int_pref.
              - now destruct prefix0.
              - destruct prefix0. inversion H. simpl in H. now destruct prefix0.
              - apply rcons_inj in H. inversion H; subst; clear H.
                apply rcons_inj in H3. inversion H3; subst; clear H3.
                inversion H1; subst; clear H1.
                now eauto.
            }
            assert (C_next_e1: C = next_comp_of_event e1).
            {
              destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
              rewrite Hprefix01 in wf_ev_comps'.
              setoid_rewrite <- app_assoc in wf_ev_comps'.
              apply trace_event_components_app_r in wf_ev_comps'.
              setoid_rewrite cats1 in wf_ev_comps'.
              inversion wf_ev_comps'. rewrite lastI in H.
              apply rcons_inj in H. inversion H. subst e2. clear H.
              rewrite -cats1 in H3. apply elt_eq_unit in H3 as [? [? _]]. subst e0 t0.
              by rewrite H0.
            }

            assert (Hcomp1 : next_comp_of_event e1 = cur_comp s).
            { by auto. }
            clear C_next_e1.
            (* NOTE: Instantiations are irrelevant! *)
            exists (EStore C reg0 reg1 s0 eregs).
            destruct (wfmem_meta wf_mem reg0 C_b) as [v0 Hreg0mem0].
            assert (Hreg0mem := Hreg0mem0).
            erewrite <- Memory.load_after_store_neq in Hreg0mem;
              last exact Hmem;
              last (injection; now destruct reg0).
            destruct (wfmem_meta wf_mem reg1 C_b) as [v1 Hreg1mem0].
            assert (Hreg1mem := Hreg1mem0).
            erewrite <- Memory.load_after_store_neq in Hreg1mem;
              last exact Hmem;
              last (injection; now destruct reg1).
            destruct (wfmem wf_mem Hprefix01) as [Hregs1 [Hsteady1 Hinitial1]].
            specialize (Hsteady1 _ C_b (Logic.eq_sym Hcomp1))
              as [Hoffset1 [Hblockid1 Hsteady1]].

            (* ... *)
            (* unfold postcondition_event_registers in Hregs1. *)
            destruct (Hregs1 (Ereg_to_reg reg0) _ (f_equal _ (reg_to_Ereg_to_reg _)))
              as [v0'' [v0' [Hreg0mem0' [Hshiftv0 Hgetv0']]]].
            rewrite Hcomp1 Hreg0mem0 in Hreg0mem0'.
            injection Hreg0mem0' as ?; subst v0''.
            rewrite Hgetptr in Hgetv0'. subst v0'.
            (* unfold well_formed_memory_snapshot_steadystate_shift in Hsnapshot1. *)

            (* NOTE: Same treatment as in the load case. *)
            assert (exists C0 b0' o0, v0 = Ptr (Permission.data, C0, S b0', o0))
              as [C0 [b0' [o0 ?]]]. {
              destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
              inversion wf_int_pref' as [| | prefint eint1 eint2 Hsteps Hstep Ht];
                [ destruct prefix; discriminate (* contra *)
                | subst prefix; destruct prefix0 as [| ? [|]]; discriminate (* contra *)
                | rewrite Hprefix01 in Ht;
                  symmetry in Ht; apply cats2_inv in Ht as [? [? ?]]; subst prefint eint1 eint2;
                  inversion Hstep as [| | | | | | tmp1 tmp2 tmp3 tmp4 ptr' tmp6 tmp7 |];
                  subst tmp1 tmp2 tmp3 tmp4 tmp6 tmp7;
                  subst eregs].
              destruct ptr' as [[[[] C'] b'] o'];
                first discriminate. (* Contra on load *) (* ptr? *)
              destruct (wfmem wf_mem Hprefix01) as [Hregs [Hsteady Hinitial]].
              destruct (Hregs (Ereg_to_reg reg0) _ Logic.eq_refl)
                as [v0'' [v0' [Hload0 [Hshift0 Hget0]]]].
              rewrite H in Hget0. subst v0'.
              rewrite reg_to_Ereg_to_reg in Hload0.
              rewrite Hcomp1 Hreg0mem0 in Hload0.
              injection Hload0 as ?; subst v0''.
              destruct v0 as [| [[[[] C0] [| b0']] o0] |]; try discriminate.
              rewrite /= /ssrnat.addn /ssrnat.addn_rec
                      /ssrnat.subn /ssrnat.subn_rec
                      /all_zeros_shift /uniform_shift
                      /= Nat.add_0_r Nat.sub_0_r in Hshift0.
              now eauto.
            }
            subst v0.

            rewrite /= /ssrnat.addn /ssrnat.addn_rec
                    /ssrnat.subn /ssrnat.subn_rec /=
                    Nat.add_0_r /= Nat.sub_0_r
              in Hshiftv0.
            injection Hshiftv0 as ?; subst ptr.

            (* destruct (Memory.store_after_load _ _ _ v1 Hreg0mem) as [mem'' Hstore']. *)
            assert (exists vptr, Memory.load mem (Permission.data, C0, S b0', o0) = Some vptr)
              as [vptr Hvptrmem]. {
              destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
              inversion wf_int_pref' as [| | prefint eint1 eint2 Hsteps Hstep Ht];
                [ destruct prefix; discriminate (* contra *)
                | subst prefix; destruct prefix0 as [| ? [|]]; discriminate (* contra *)
                | rewrite Hprefix01 in Ht;
                  symmetry in Ht; apply cats2_inv in Ht as [? [? ?]]; subst prefint eint1 eint2;
                  inversion Hstep as [| | | | | | tmp1 tmp2 tmp3 tmp4 ptr' tmp6 tmp7 |];
                  subst tmp1 tmp2 tmp3 tmp4 tmp6 tmp7;
                  subst eregs].

              destruct ptr' as [[[[] C'] b'] o'];
                first discriminate. (* Contra on load *)
              destruct (wfmem wf_mem Hprefix01) as [Hregs [Hsteady Hinitial]].
              destruct (Hregs (Ereg_to_reg reg0) _ Logic.eq_refl)
                as [v0'' [v0' [Hload0 [Hshift0 Hget0]]]].
              rewrite H in Hget0. subst v0'.
              rewrite reg_to_Ereg_to_reg in Hload0.
              rewrite Hcomp1 Hreg0mem0 in Hload0.
              injection Hload0 as ?; subst v0''.
              rewrite /= /ssrnat.addn /ssrnat.addn_rec
                      /ssrnat.subn /ssrnat.subn_rec
                      /all_zeros_shift /uniform_shift
                      /= Nat.add_0_r Nat.sub_0_r in Hshift0.
              injection Hshift0 as ? ? ?; subst C' b' o'.

              destruct (proj2 (Memory.store_some_load_some _ _ _) (ex_intro _ _ H0))
                as [vptr Hloadptr].
              destruct (Nat.eqb_spec C C0) as [| Hneq].
              - (* Same as initialized external component below. *)
                subst C0.
                destruct (Hsteady _ C_b (Logic.eq_sym Hcomp1))
                  as [Hinitflag0 [Hlocalbuf [Hshift0 Hblock0]]].
                destruct (Hshift0 (S b0') (Nat.neq_succ_0 _))
                  as [[cid bid] [Hshift0' [Hrename0 Hrename0']]].
                rewrite shift_S_Some in Hshift0'.
                injection Hshift0' as ? ?; subst cid bid.
                destruct (Hrename0' _ _ Hloadptr) as [v' [Hload' Hshift']].
                eexists. simplify_memory'. exact Hload'.
              - assert (C0_b : component_buffer C0). (* NOTE: Also used above, should be a lemma. *)
                {
                  unfold component_buffer.
                  change C0 with (Pointer.component (Permission.data, C0, S b0', o0)).
                  (* change intf with (Source.prog_interface p). *)
                  assert (Hrewr: intf = Source.prog_interface p).
                  { by subst p. }
                  rewrite Hrewr. clear Hrewr.                                                
                  eapply CS.load_component_prog_interface; try exact Star0; eauto.
                  -
                    {
                      eapply well_formed_events_well_formed_program
                      in wf_events as [theprog [Hrewr ?]]; eauto.
                      + erewrite Hprog_of_trace in Hrewr. inversion Hrewr.
                        by subst theprog.
                      + by eapply domm_t_procs_exported_procedures_of_trace.
                    }
                  - eapply closed_program_of_trace; by eauto.
                  - reflexivity.
                }
                apply nesym in Hneq.
                rewrite /C -Hcomp1 in Hneq.
                destruct (Hinitial _ C0_b Hneq) as [Hsteady0 | Hinitial0].
                + (* Initialized component. The proof can proceed as usual. The
                   shifting relation allows us to identify the pointer in the
                   registers file and the pointer in the simulated memory, and
                   conclude in particular the equality of both components. *)
                  destruct Hsteady0
                    as [Hinitflag0 [Hlocalbuf [Hshift0 Hblock0]]].
                  destruct (Hshift0 (S b0') (Nat.neq_succ_0 _))
                    as [[cid bid] [Hshift0' [Hrename0 Hrename0']]].
                  rewrite shift_S_Some in Hshift0'.
                  injection Hshift0' as ? ?; subst cid bid.
                  destruct (Hrename0' _ _ Hloadptr) as [v' [Hload' Hshift']].
                  eexists. simplify_memory'. exact Hload'.
                + (* Uninitialized component: contradiction. Only the metadata
                   buffer is available, yet we can obtain a successful load
                   outside said buffer. *)
                  destruct Hinitial0
                    as [Hinitialflag [Hlocalbuf [[Hprealloc Hnextblock] Hnot_shared]]].
                  destruct Hprealloc as [Cmem [buf [HCmem [Hbuf [Hnext Hprealloc]]]]].
                  destruct Hnextblock as [mem0C0 [Hmem0C0 Hnext0]].
                  assert (wf_p : Source.well_formed_program p).
                  {
                    eapply well_formed_events_well_formed_program
                      in wf_events as [theprog [Hrewr ?]]; eauto.
                    + erewrite Hprog_of_trace in Hrewr. inversion Hrewr.
                      by subst theprog.
                    + by eapply domm_t_procs_exported_procedures_of_trace.
                  }
                  assert (Hclosed_: Source.closed_program p).
                  { by eapply closed_program_of_trace; eauto. }

                  destruct (CS.load_data_next_block
                              wf_p Hclosed_ Logic.eq_refl
                              Star0 Hreg0mem0)
                    as [Cmem0'' [HCmem0'' Hcontra]].
                  rewrite Hmem0C0 in HCmem0''.
                  injection HCmem0'' as ?; subst Cmem0''.
                  rewrite Hnext0 /LOCALBUF_blockid in Hcontra. lia.
            }
            destruct (Memory.store_after_load _ _ _ v1 Hvptrmem) as [mem'' Hstore'].

            (* Is this useful? *)
            destruct (Hregs1 (Ereg_to_reg reg1) _ (f_equal _ (reg_to_Ereg_to_reg _)))
              as [v1'' [v1' [Hreg1mem0' [Hshiftv1 Hgetv1']]]].
            subst v1'.
            rewrite Hcomp1 Hreg1mem0 in Hreg1mem0'.
            injection Hreg1mem0' as ?; subst v1''.

            exists (StackState C (callers s)).
            eexists.
            split; [| split].
            + (* Evaluate steps of back-translated event first. *)
              Local Transparent expr_of_const_val loc_of_reg.
              take_steps.
              * exact Hreg1mem.
              * take_steps.
                -- exact Hreg0mem.
                -- take_steps.
                   ++ exact Hstore'.
                   ++ (* Do recursive call. *)
                     take_steps.
                     ** eapply find_procedures_of_trace; by subst; eauto.
                     ** (* Now we are done with the event.
                          We still need to process the external call check. *)
                       take_steps.
                       --- destruct (wfmem wf_mem Hprefix01) as [_ [Hsteady _]].
                           specialize (Hsteady _ C_b (Logic.eq_sym Hcomp1)) as [Hoffset _].
                           erewrite Memory.load_after_store_neq;
                             last exact Hstore';
                             last (injection; discriminate).
                           erewrite Memory.load_after_store_neq;
                             last exact Hmem;
                             last (injection; discriminate).
                           exact Hoffset.
                       --- take_steps.
                           +++ assert (Hload0 := proj1 (wfmem_extcall wf_mem Hprefix01) _ C_b (Logic.eq_sym Hcomp1)).
                               rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hstore');
                                 last (now destruct reg0). (* Trivial property of register offsets. *)
                               rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem);
                                 last easy.
                               exact Hload0.
                           +++ unfold invalidate_metadata.
                               take_steps.
                               apply star_refl.
            + (* Reestablish invariant. *)
              econstructor; try reflexivity; try eassumption.
              { by rewrite Et; subst. }
              { destruct s. exact wb. }
              { destruct wf_stk as [top [bot [Heq [Htop Hbot]]]]; subst stk.
                eexists ({| CS.f_component := C; CS.f_arg := arg; CS.f_cont := Kstop |} :: top).
                exists bot. split; [reflexivity| split; [easy |]].
                elim: (callers s) bot Hbot {Star0 Star1}; trivial.
                move=> a l IH bot [] H1 H2.
                fold well_formed_callers in *.
                split.
                ++ simplify_memory.
                ++ destruct H2 as [? [? [? [? [? [? [? H2]]]]]]].
                   eexists; eexists; eexists; eexists.
                   repeat split; eauto. }
              (* Reestablish memory well-formedness.
               TODO: Refactor, automate. *)
              { (* destruct wf_mem as [wfmem_counter wfmem_meta wfmem]. *)
                (* instantiate (1 := mem). (* FIXME *) *)
                constructor.
                - intros C_ Hcomp.
                  destruct (Nat.eqb_spec C C_) as [Heq | Hneq].
                  + subst C_.
                    pose proof Memory.load_after_store_eq _ _ _ _ Hmem as Hmem0.
                    (* assert (Hoffsetneq' : (Permission.data, C, Block.local, reg_offset reg0) <> (Permission.data, C, Block.local, 0%Z)) *)
                    (*   by (now destruct reg0). *)
                    erewrite Memory.load_after_store_neq;
                      last exact Hstore';
                      last (injection; discriminate).
                    assumption.
                  + erewrite Memory.load_after_store_neq;
                      last eassumption;
                      last (injection; discriminate).
                    assert (Hload0 := wfmem_counter wf_mem Hcomp).
                    assert (HCneq : (Permission.data, C, Block.local, 0%Z) <> (Permission.data, C_, Block.local, 0%Z))
                      by (now injection). (* Easy contradiction. *)
                    rewrite <- (Memory.load_after_store_neq _ _ _ _ _ HCneq Hmem) in Hload0.
                    rewrite counter_value_snoc. simpl.
                    move: Hneq => /eqP.
                    case: ifP;
                      last now rewrite Z.add_0_r.
                    move => /eqP => Hcontra => /eqP => Hneq.
                    symmetry in Hcontra. contradiction.
                - intros Hcontra. now destruct prefix.
                - intros pref ev Hprefix.
                  apply rcons_inv in Hprefix as [? ?]; subst pref ev.
                  split.
                  + intros C_ Hcomp Hnext.
                    destruct (Nat.eqb_spec C C_) as [Heq | Hneq].
                    * subst C_.
                      rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hstore');
                        last (injection; destruct reg0; discriminate).
                      rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem);
                        last (injection; discriminate).
                      apply (proj1 (wfmem_extcall wf_mem Hprefix01) _ Hcomp).
                      now rewrite Hcomp1.
                    * symmetry in Hnext. contradiction.
                  + intros C_ Hcomp Hnext.
                    destruct (Nat.eqb_spec C C_) as [Heq | Hneq].
                    * subst C_. contradiction.
                    * rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hstore');
                        last (injection; destruct reg0; discriminate).
                      rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem);
                        last (injection; discriminate).
                      apply (proj2 (wfmem_extcall wf_mem Hprefix01) _ Hcomp).
                      intro; subst C_.
                      contradiction.
                - intros C_ reg Hcomp.
                  (* This sub-proof becomes simpler. *)
                  erewrite Memory.load_after_store_neq;
                    last exact Hstore';
                    last (injection; discriminate).
                  erewrite Memory.load_after_store_neq;
                    last exact Hmem;
                    last (destruct reg; discriminate).
                  eapply wfmem_meta; now eauto.
                - intro Hcontra. now destruct prefix.
                - intros pref ev Hprefix.
                  apply rcons_inv in Hprefix as [? ?]; subst pref ev.
                  destruct (wfmem wf_mem Hprefix01) as [Hpostregs [Hsteady Hinitial]]. (* NOTE: Repeated assumptions above! *)
                  (* rename n into n0. rename v into v0. rename Hload into Hload0. rename mem' into mem'0. *) rename s0 into mem'. (* Trying to preserve proof script... *)
                  split; [| split].
                  + { (* No register changes, thus simpler proof. *)
                    (* subst mem'. *)
                    intros n off Hoffset.
                    simpl in *.
                    (* subst v prefix. *)
                    unfold postcondition_event_registers in Hpostregs.
                    destruct (Hpostregs _ _ Hoffset)
                      as [vtmp [v'' [Hload'' [Hshift'' Hget'']]]].
                    eexists. eexists. split; [| split].
                    - erewrite Memory.load_after_store_neq;
                        last exact Hstore';
                        last (injection; discriminate).
                      erewrite Memory.load_after_store_neq;
                        last exact Hmem;
                        last (subst off; injection; by destruct n).
                      rewrite -Hcomp1.
                      exact Hload''.
                    - exact Hshift''.
                    - destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
                      inversion wf_int_pref' as [| | prefint eint1 eint2 Hsteps Hstep Ht];
                        [ destruct prefix; discriminate (* contra *)
                        | subst prefix; destruct prefix0 as [| ? [|]]; discriminate (* contra *)
                        | rewrite Hprefix01 in Ht;
                          symmetry in Ht; apply cats2_inv in Ht as [? [? ?]]; subst prefint eint1 eint2;
                          inversion Hstep as [| | | | | | tmp1 tmp2 tmp3 tmp4 tmp5 tmp6 tmp7 |];
                          subst tmp1 tmp2 tmp3 tmp4 tmp6 tmp7;
                          subst eregs].
                      exact Hget''.
                  }
                  + intros C' _ ?; subst C'. simpl.
                    specialize (Hsteady _ C_b (Logic.eq_sym Hcomp1))
                      as [Hinitflag [Hlocalbuf [Hsnapshot Hnextblock]]].
                    split; [| split; [| split]].
                    (* The first two sub-goals are near-identical arguments on
                     memory operations. *)
                    * erewrite Memory.load_after_store_neq;
                      last exact Hstore';
                      last (injection; discriminate).
                      erewrite Memory.load_after_store_neq;
                        last exact Hmem;
                        last (injection; discriminate).
                      exact Hinitflag.
                    * erewrite Memory.load_after_store_neq;
                        last exact Hstore';
                        last (injection; discriminate).
                      erewrite Memory.load_after_store_neq;
                        last exact Hmem;
                        last (injection; discriminate).
                      exact Hlocalbuf.
                    (* ... *)
                    * intros b Hb. simpl.
                      (* Instead of specialize... (?) *)
                      destruct (Hsnapshot b Hb) as [[cid bid] [Hshift' [Hrename Hrename']]].
                      destruct b as [| b'];
                        first discriminate.
                      rewrite shift_S_Some in Hshift'.
                      injection Hshift' as ? ?; subst cid bid.
                      exists (C, b'). split; [| split].
                      (* eexists. split; [| split]. *)
                      -- rewrite shift_S_Some.
                         reflexivity.
                      -- simpl. intros off v' Hload'.
                         simpl in Hrename.
                         (* ... *)
                         destruct (Pointer.eqP
                                     (Permission.data, C, b', off)
                                     (Permission.data, C0, b0', o0)) as [Heq | Hneq].
                         ++ injection Heq as ? ? ?; subst C0 b0' o0.
                            erewrite Memory.load_after_store_eq in Hload';
                              last exact Hstore'.
                            injection Hload' as ?; subst v'.
                            eexists. split.
                            ** erewrite Memory.load_after_store_eq;
                                 last exact Hstore.
                               reflexivity.
                            ** rewrite -Hshiftv1.
                               reflexivity.
                         ++ erewrite Memory.load_after_store_neq in Hload';
                              last exact Hstore';
                              last (injection as ? ? ?; subst C0 b0' o0; contradiction).
                            erewrite Memory.load_after_store_neq in Hload';
                              last exact Hmem;
                              last (injection; discriminate).
                            (* Instead of specialize... (?) *)
                            destruct (Hrename _ _ Hload') as [v'' [Hload'' Hrename'']].
                            eexists. split.
                            ** erewrite Memory.load_after_store_neq;
                                 last exact Hstore;
                                 last by intuition. (* Better than case analysis! *)
                               exact Hload''.
                            ** exact Hrename''.
                      -- simpl. intros off v' Hload'.
                         simpl in Hrename'.
                         (* ... *)
                         destruct (Pointer.eqP
                                     (Permission.data, C, b', off)
                                     (Permission.data, C0, b0', o0)) as [Heq | Hneq].
                         ++ injection Heq as ? ? ?; subst C0 b0' o0.
                            erewrite Memory.load_after_store_eq in Hload';
                              last exact Hstore.
                            injection Hload' as ?; subst v'.
                            eexists. split.
                            ** erewrite Memory.load_after_store_eq;
                                 last exact Hstore'.
                               reflexivity.
                            ** rewrite -Hshiftv1.
                               reflexivity.
                         ++ erewrite Memory.load_after_store_neq in Hload';
                              last exact Hstore;
                              last by intuition.
                            destruct (Hrename' _ _ Hload') as [v'' [Hload'' Hrename'']].
                            eexists. split.
                            ** erewrite Memory.load_after_store_neq;
                                 last exact Hstore';
                                 last (injection as ? ? ?; subst C0 b0' o0; contradiction).
                               erewrite Memory.load_after_store_neq;
                                 last exact Hmem;
                                 last (injection; discriminate).
                               exact Hload''.
                            ** exact Hrename''.
                    * intros next Hnext.
                      erewrite Memory.next_block_store_stable in Hnext;
                        last exact Hstore.
                      (* rewrite Hmem' in Hnext. *)
                      specialize (Hnextblock next Hnext).
                      erewrite Memory.next_block_store_stable;
                        last exact Hstore'.
                      erewrite Memory.next_block_store_stable;
                        last exact Hmem.
                      exact Hnextblock.
                  + intros C' Hcomp Hnext.
                    destruct (Nat.eqb_spec C0 C') as [| Hneq].
                    { (* Store-specific sub-proof *)
                      subst C0.
                      rewrite <- Hcomp1 in Hnext.
                      (* specialize (Hinitial _ Hcomp Hnext) as [Hsteady' | Hinitial]. *)
                      assert (Hsteady' : postcondition_steady_state e1 mem0 C'). {
                        eapply load_postcondition_steady_state.
                        - apply Hinitial; auto.
                        - erewrite Memory.load_after_store_neq in Hvptrmem; eauto.
                          injection; discriminate.
                      }
                      (* left. (* There is only one way to go. *) *)
                      destruct Hsteady' as [Hinitflag [Hlocalbuf Hsteady']].
                      left. split; [| split].
                      -- erewrite Memory.load_after_store_neq;
                           last exact Hstore';
                           last (injection; discriminate).
                         erewrite Memory.load_after_store_neq;
                           last exact Hmem;
                           last (injection; discriminate).
                         exact Hinitflag.
                      -- erewrite Memory.load_after_store_neq;
                           last exact Hstore';
                           last (injection; discriminate).
                         erewrite Memory.load_after_store_neq;
                           last exact Hmem;
                           last (injection; discriminate).
                         exact Hlocalbuf.
                      -- destruct Hsteady' as [Hsnapshot Hnextblock].
                         split.
                         ++ intros b Hlocal.
                            specialize (Hsnapshot b Hlocal) as [Cb [Hshift' [Hrename Hrename']]].
                            exists Cb. split; [| split].
                            ** exact Hshift'. (* Goes away, trivial property though *)
                            ** intros off v' Hload. simpl.
                               destruct b as [| b']; first discriminate.
                               rewrite shift_S_Some in Hshift'.
                               injection Hshift' as ?; subst Cb. (* Should be done upfront *)
                               (* Where should we do case analysis on pointer equality? *)
                               destruct (Pointer.eqP
                                           (Permission.data, C', b', off)
                                           (Permission.data, C', b0', o0))
                                 as [Heq | Hneq].
                               --- injection Heq as ? ?; subst b0' o0.
                                   erewrite Memory.load_after_store_eq in Hload;
                                     last exact Hstore'.
                                   injection Hload as ?; subst v'.
                                   eexists. split.
                                   +++ erewrite Memory.load_after_store_eq;
                                         last exact Hstore.
                                       reflexivity.
                                   +++ exact Hshiftv1.
                               --- erewrite Memory.load_after_store_neq in Hload;
                                     last exact Hstore';
                                     last (injection; congruence).
                                   erewrite Memory.load_after_store_neq in Hload;
                                     last exact Hmem;
                                     last (injection; discriminate).
                                   specialize (Hrename off v' Hload) as [v'' [Hload'' Hrename]].
                                   exists v''. split.
                                   +++ erewrite Memory.load_after_store_neq;
                                         last exact Hstore;
                                         last (injection; congruence).
                                       exact Hload''.
                                   +++ congruence.
                            ** intros off v' Hload.
                               destruct b as [| b']; first discriminate.
                               rewrite shift_S_Some in Hshift'.
                               injection Hshift' as ?; subst Cb. (* Should be done upfront *)
                               simpl in Hload.
                               (* Where should we do case analysis on pointer equality? *)
                               destruct (Pointer.eqP
                                           (Permission.data, C', b', off)
                                           (Permission.data, C', b0', o0))
                                 as [Heq | Hneq].
                               --- injection Heq as ? ?; subst b0' o0.
                                   erewrite Memory.load_after_store_eq in Hload;
                                     last exact Hstore.
                                   injection Hload as ?; subst v'.
                                   eexists. split.
                                   +++ erewrite Memory.load_after_store_eq;
                                         last exact Hstore'.
                                       reflexivity.
                                   +++ exact Hshiftv1.
                               --- erewrite Memory.load_after_store_neq in Hload;
                                     last exact Hstore;
                                     last (injection; congruence).
                                   specialize (Hrename' off v' Hload) as [v'' [Hload'' Hrename']].
                                   exists v''. split.
                                   +++ erewrite Memory.load_after_store_neq;
                                         last exact Hstore';
                                         last (injection; congruence).
                                       erewrite Memory.load_after_store_neq;
                                         last exact Hmem;
                                         last (injection; congruence).
                                       assumption.
                                   +++ congruence.
                         ++ (* Same sub-proof on next block as above! *)
                           intros next Hnext'.
                           erewrite Memory.next_block_store_stable in Hnext';
                             last exact Hstore.
                           specialize (Hnextblock next Hnext').
                           erewrite Memory.next_block_store_stable;
                             last exact Hstore'.
                           erewrite Memory.next_block_store_stable;
                             last exact Hmem.
                           exact Hnextblock.
                    }
                    { (* The standard proof works in this case *)
                      rewrite <- Hcomp1 in Hnext.
                      specialize (Hinitial _ Hcomp Hnext) as [Hsteady' | Hinitial].
                      * destruct Hsteady' as [Hinitflag [Hlocalbuf Hsteady']].
                        left. split; [| split].
                        -- erewrite Memory.load_after_store_neq;
                             last exact Hstore';
                             last (injection; discriminate).
                           erewrite Memory.load_after_store_neq;
                             last exact Hmem;
                             last (injection; discriminate).
                           exact Hinitflag.
                        -- erewrite Memory.load_after_store_neq;
                             last exact Hstore';
                             last (injection; discriminate).
                           erewrite Memory.load_after_store_neq;
                             last exact Hmem;
                             last (injection; discriminate).
                           exact Hlocalbuf.
                        -- destruct Hsteady' as [Hsnapshot Hnextblock].
                           split.
                           ++ intros b Hlocal.
                              specialize (Hsnapshot b Hlocal) as [Cb [Hshift' [Hrename Hrename']]].
                              exists Cb. split; [| split].
                              ** exact Hshift'. (* Goes away, trivial property though *)
                              ** intros off v' Hload.
                                 erewrite Memory.load_after_store_neq in Hload;
                                   last exact Hstore';
                                   last (injection as ? ? ?; contradiction).
                                 erewrite Memory.load_after_store_neq in Hload;
                                   last exact Hmem;
                                   last (injection as ? ? ?; subst C' b off; contradiction).
                                 specialize (Hrename off v' Hload) as [v'' [Hload'' Hrename]].
                                 exists v''. split.
                                 --- (* Cf. Hstore, Hshift' (should be treated upfront) *)
                                   destruct b as [| b']; first discriminate.
                                   rewrite shift_S_Some in Hshift'.
                                   injection Hshift' as ?; subst Cb.
                                   erewrite Memory.load_after_store_neq;
                                     last exact Hstore;
                                     last (injection; contradiction).
                                   exact Hload''.
                                 --- congruence.
                              ** intros off v' Hload.
                                 destruct b as [| b']; first discriminate.
                                 rewrite shift_S_Some in Hshift'.
                                 injection Hshift' as ?; subst Cb. (* Should be done upfront *)
                                 erewrite Memory.load_after_store_neq in Hload;
                                   last exact Hstore;
                                   last (injection; congruence).
                                 specialize (Hrename' off v' Hload) as [v'' [Hload'' Hrename']].
                                 exists v''. split.
                                 --- erewrite Memory.load_after_store_neq;
                                       last exact Hstore';
                                       last (injection; contradiction).
                                     erewrite Memory.load_after_store_neq;
                                       last exact Hmem;
                                       last (injection; discriminate).
                                     assumption.
                                 --- congruence.
                           ++ (* Same sub-proof on next block as above! *)
                             intros next Hnext'.
                             erewrite Memory.next_block_store_stable in Hnext';
                               last exact Hstore.
                             specialize (Hnextblock next Hnext').
                             erewrite Memory.next_block_store_stable;
                               last exact Hstore'.
                             erewrite Memory.next_block_store_stable;
                               last exact Hmem.
                             exact Hnextblock.
                      * right.
                        destruct Hinitial as [Hinitflag [Hlocalbuf [Hinitial Hnot_shared]]].
                        split; [| split; [| split]].
                        -- erewrite Memory.load_after_store_neq;
                             last exact Hstore';
                             last (injection; discriminate).
                           erewrite Memory.load_after_store_neq;
                             last exact Hmem;
                             last (injection; discriminate).
                           exact Hinitflag.
                        -- erewrite Memory.load_after_store_neq;
                             last exact Hstore';
                             last (injection; discriminate).
                           erewrite Memory.load_after_store_neq;
                             last exact Hmem;
                             last (injection; discriminate).
                           exact Hlocalbuf.
                        -- destruct Hinitial as [Hprealloc Hnextblock].
                           split.
                           ** destruct Hprealloc
                                as [Cmem [buf [HCmem [Hbuf [Hnextblock' Hprealloc]]]]].
                              exists Cmem, buf.
                              split; [| split; [| split]]; try assumption.
                              rewrite -HCmem. symmetry.
                              by eapply component_memory_after_store_neq; eauto.
                           ** destruct Hnextblock as [Cmem [HCmem Hnextblock]].
                              exists Cmem. split; last assumption.
                              rewrite -HCmem. symmetry.
                              transitivity (mem C').
                              --- eapply component_memory_after_store_neq; eauto.
                                  intro Hcontra. apply Hnext. rewrite -Hcontra. easy.
                              --- by eapply component_memory_after_store_neq; eauto.
                        -- by rewrite -cats1 project_non_inform_append /= E0_right Hprefix01 cats1.
                    }
                - move=> ptr cid bid off.
                  destruct (Pointer.eq ptr (Permission.data, C0, S b0', o0)) eqn:eq_ptr;
                    move: eq_ptr =>
                             /Pointer.eqP eq_ptr; subst;
                             [erewrite Memory.load_after_store_eq; eauto; try by []
                             | erewrite Memory.load_after_store_neq; eauto; clear eq_ptr].
                  destruct v1 as [| [[[[]]]] |]; try by [].
                  intros R; inversion R; subst; clear R.
                  rewrite /all_zeros_shift /uniform_shift in Hshiftv1. simpl in Hshiftv1.
                  rewrite /rename_addr_option /sigma_shifting_wrap_bid_in_addr
                          /sigma_shifting_lefttoright_addr_bid /sigma_shifting_lefttoright_option
                    in Hshiftv1.
                  destruct bid; try discriminate.
                  destruct (Pointer.eq ptr (Permission.data, C, Block.local, 0%Z)) eqn:eq_ptr;
                    move: eq_ptr =>
                             /Pointer.eqP eq_ptr; subst;
                             [erewrite Memory.load_after_store_eq; eauto; try by []
                             | erewrite Memory.load_after_store_neq; eauto; clear eq_ptr].
                  by eapply wfmem_no_private_ptr; eauto.
              }
            + simpl.
              rewrite project_non_inform_append /=.
              rewrite -> !cats0.
              by inversion Hshift; eauto.

          - (* EAlloc *)
            (* Gather a few recurrent assumptions at the top. *)
            rename e into reg0. rename e0 into reg1.
            (* rename s0 into emem. *)
            rename t0 into eregs.
            assert (prefix = [::] \/ exists prefix' e', prefix = prefix' ++ [:: e'])
              as [Hprefix | [prefix0 [e1 Hprefix01]]].
            {
              destruct prefix; first by auto.
              right. rewrite lastI -cats1. by eauto.
            }
            { (* Treat empty case separately. *)
              exfalso. (* Nothing to do in the alloc case. *)
              subst prefix. simpl in *.
              (* NOTE: This should come from well-formedness of events. *)
              destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
              inversion wf_int_pref';
                last now destruct prefix as [|? []].
              subst e.
              inversion H0. subst eregs regs mem1 C erptr ersize mem' regs'.
              destruct (Machine.Intermediate.Register.eqP (Ereg_to_reg reg1) Machine.R_COM) as [Heq | Hneq].
              - rewrite Heq Machine.Intermediate.Register.gss in H6.
                injection H6 as ?; subst size.
                lia.
              - rewrite Machine.Intermediate.Register.gso in H6;
                  last exact Hneq.
                rewrite /Machine.Intermediate.Register.get
                        Machine.Intermediate.Register.reg_in_domm_init_Undef in H6;
                  last (apply /dommP; exists Undef; now destruct reg1).
                by destruct reg1.
            }
            (* Extract known memory facts. *)
            assert (exists size ptr,
                       Machine.Intermediate.Register.get (Ereg_to_reg reg1) (register_file_of_event_inform e1) = Int size /\
                         (size > 0)%Z /\
                         Memory.alloc (mem_of_event_inform e1) (cur_comp s) (Z.to_nat size) = Some (s0, ptr))
              as [size [ptr [Hregse1 [Hsize' Halloc']]]]. {
              subst prefix.
              clear -wf_int_pref'.
              (* Maybe keep shift? *)
              move: wf_int_pref'; rewrite !cats1 => [[wf_int_pref _]].
              inversion wf_int_pref.
              - now destruct prefix0.
              - destruct prefix0. inversion H. simpl in H. now destruct prefix0.
              - apply rcons_inj in H. inversion H; subst; clear H.
                apply rcons_inj in H3. inversion H3; subst; clear H3.
                inversion H1; subst; clear H1.
                now eauto.
            }
            assert (C_next_e1: C = next_comp_of_event e1).
            {
              destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
              rewrite Hprefix01 in wf_ev_comps'.
              setoid_rewrite <- app_assoc in wf_ev_comps'.
              apply trace_event_components_app_r in wf_ev_comps'.
              setoid_rewrite cats1 in wf_ev_comps'.
              inversion wf_ev_comps'. rewrite lastI in H.
              apply rcons_inj in H. inversion H. subst e2. clear H.
              rewrite -cats1 in H3. apply elt_eq_unit in H3 as [? [? _]]. subst e0 t0.
              by rewrite H0.
            }

            assert (Hcomp1 : next_comp_of_event e1 = cur_comp s).
            { by auto. }
            clear C_next_e1.
            (* NOTE: Instantiations! [ptr] seems to have no effect in the proofs. *)
            exists (EAlloc C reg0 reg1 s0 eregs).
            (* TODO: Clean assumptions, refactor. *)
            destruct (wfmem_meta wf_mem reg0 C_b) as [v0 Hreg0mem0].
            assert (Hreg0mem := Hreg0mem0).
            erewrite <- Memory.load_after_store_neq in Hreg0mem;
              last exact Hmem;
              last (injection; now destruct reg0).
            destruct (wfmem_meta wf_mem reg1 C_b) as [v1 Hreg1mem0].
            assert (Hreg1mem := Hreg1mem0).
            erewrite <- Memory.load_after_store_neq in Hreg1mem;
              last exact Hmem;
              last (injection; now destruct reg1).
            destruct (wfmem wf_mem Hprefix01) as [Hregs1 [Hsteady1 Hinitial1]].
            specialize (Hsteady1 _ C_b (Logic.eq_sym Hcomp1)) as [Hoffset1 [Hblockid1 [Hsnapshot1 Hblock1]]].
            (* Some alloc-specific reasoning... *)
            (* NOTE: This should come from well-formedness of events. *)
            destruct wf_int_pref' as [wf_int_pref' wf_ev_comps'].
            inversion wf_int_pref';
              [now destruct prefix |
                subst prefix; now destruct prefix0 as [|? []]
              | ].
            rewrite Hprefix01 in H. do 2 rewrite cats1 in H. apply rcons_inj in H. injection H as ? ?; subst e'. apply rcons_inj in H. injection H as ? ?; subst prefix1 e.
            (* Cf. tactic find_rcons_rcons *)
            inversion H1. subst eregs regs mem1 C0 erptr ersize mem' regs'.
            destruct (Hregs1 (Ereg_to_reg reg1) _ Logic.eq_refl) as [v1'' [v1' [Hshift1 [Hshift1' Hget1]]]].
            rewrite H7 in Hget1. subst v1'.
            rewrite reg_to_Ereg_to_reg in Hshift1.
            destruct v1'' as [| [[[[] ?] []] ?] | ]; try discriminate.
            injection Hshift1' as ?; subst z.
            rename size0 into n1.
            rename H9 into Hsize.
            rewrite Hcomp1 in Hshift1.
            rewrite Hreg1mem0 in Hshift1.
            injection Hshift1 as ?; subst v1.
            destruct (Memory.next_block_alloc _ _ _ _ _ Halloc') as [Hnexte1 Hnexts0].
            destruct ptr as [[[pptr Cptr] bptr] optr].
            injection (Memory.pointer_of_alloc _ _ _ _ _ _ Halloc' Hnexte1) as ? ? ?; subst pptr Cptr optr.
            (* NOTE: In previous cases, we got to the store by a different route. *)
            destruct (Memory.alloc_after_load _ _ _ _ _ _ (Z.to_nat n1) Hreg0mem)
              as [mem' [bnew [Hb' Halloc]]].
            (* Some more work on this second alloc... *)
            destruct (Memory.next_block_alloc _ _ _ _ _ Halloc) as [Hnextmem Hnextmem'].
            simpl in Hnextmem, Hnextmem'.
            specialize (Hblock1 _ Hnexte1).
            rewrite <- (Memory.next_block_store_stable _ _ _ _ _ Hmem) in Hblock1.
            rewrite Hblock1 in Hnextmem.
            injection Hnextmem as ?; subst bnew.
            unfold postcondition_event_registers in Hregs1.
            destruct (Hregs1 (Ereg_to_reg reg1) _ Logic.eq_refl)
              as [v1 [v1' [Hloadv1 [Hshiftv1 Hgetv1']]]].
            rewrite Hregse1 in Hgetv1'; subst v1'.
            rewrite reg_to_Ereg_to_reg Hcomp1 Hreg1mem0 in Hloadv1.
            injection Hloadv1 as ?; subst v1.
            injection Hshiftv1 as ?; subst size.
            (* ... *)
            set (saved := Ptr (Permission.data, cur_comp s, S bptr, 0%Z)).
            assert (Hreg0mem' := Hreg0mem).
            erewrite <- Memory.load_after_alloc in Hreg0mem';
              [| exact Halloc | injection; congruence].
            destruct (Memory.store_after_load _ _ _ saved Hreg0mem') as [mem'' Hstore']. (* "Standard" names here... *)
            (* Continue. *)
            exists (StackState C (callers s)).
            eexists. (* evar (CS : state (CS.sem p)). exists CS. *)
            split; [| split].
            + (* Evaluate steps of back-translated event first. *)
              Local Transparent expr_of_const_val loc_of_reg.
              take_steps.
              * exact Hreg1mem.
              * take_steps.
                -- exact Hsize.
                -- exact Halloc.
                -- take_steps.
                   ++ exact Hstore'.
                   ++ (* Do recursive call. *)
                     take_steps.
                     ** by eapply find_procedures_of_trace; subst; eauto.
                     ** (* Now we are done with the event.
                          We still need to process the external call check. *)
                       take_steps.
                       --- destruct (wfmem wf_mem Hprefix01) as [_ [Hsteady _]].
                           specialize (Hsteady _ C_b (Logic.eq_sym Hcomp1)) as [Hoffset _].
                           erewrite Memory.load_after_store_neq;
                             last exact Hstore';
                             last (injection; now destruct reg0).
                           erewrite Memory.load_after_alloc;
                             [| exact Halloc | injection; discriminate].
                           erewrite Memory.load_after_store_neq;
                             last exact Hmem;
                             last (injection; now destruct reg0).
                           exact Hoffset.
                       --- take_steps.
                           +++ assert (Hload0 := proj1 (wfmem_extcall wf_mem Hprefix01) _ C_b (Logic.eq_sym Hcomp1)).
                               rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hstore');
                                 last (now destruct reg0). (* Trivial property of register offsets. *)
                               (* Alloc-specific *)
                               erewrite Memory.load_after_alloc;
                                 [| exact Halloc | injection; congruence].
                               rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem);
                                 last easy.
                               exact Hload0.
                           +++ unfold invalidate_metadata.
                               take_steps.
                               apply star_refl.
            + (* Reestablish invariant. *)
              econstructor; try reflexivity; try eassumption.
              { by rewrite Et; subst. }
              { destruct s. exact wb. }
              { destruct wf_stk as [top [bot [Heq [Htop Hbot]]]]; subst stk.
                eexists ({| CS.f_component := C; CS.f_arg := arg; CS.f_cont := Kstop |} :: top).
                exists bot. split; [reflexivity | split; [easy |]].
                elim: (callers s) bot Hbot {Star0 Star1}; trivial.
                move=> a l IH bot [] H2 H3.
                fold well_formed_callers in *.
                split.
                ++ simplify_memory'. eauto.
                (* destruct (a == ) eqn:eq; *)
                (*   move: eq => /eqP eq; subst. *)
                (* simplify_memory. *)
                (* ** now destruct Postcond1. *)
                (* ** rewrite -Hmem2'; last congruence. *)
                (*    now simplify_memory. *)
                ++ destruct H3 as [? [? [? [? [? [? [? H3]]]]]]].
                   eexists; eexists; eexists; eexists.
                   repeat split; eauto. }
              (* Reestablish memory well-formedness.
               TODO: Refactor, automate. *)
              { (* destruct wf_mem as [wfmem_counter wfmem_meta wfmem]. *)
                (* instantiate (1 := mem). (* FIXME *) *)
                constructor.
                - intros C_ Hcomp.
                  destruct (Nat.eqb_spec C C_) as [Heq | Hneq].
                  + subst C_.
                    pose proof Memory.load_after_store_eq _ _ _ _ Hmem as Hmem0.
                    assert (Hoffsetneq' : (Permission.data, C, Block.local, reg_offset reg0) <> (Permission.data, C, Block.local, 0%Z))
                      by (now destruct reg0).
                    rewrite (Memory.load_after_store_neq _ _ _ _ _ Hoffsetneq' Hstore').
                    erewrite Memory.load_after_alloc;
                      [| exact Halloc | injection; congruence].
                    (* rewrite -cats1. *)
                    subst prefix.
                    rewrite -cats2.
                    assumption.
                  + erewrite Memory.load_after_store_neq;
                      last eassumption;
                      last (injection; contradiction).
                    assert (Hload0 := wfmem_counter wf_mem Hcomp).
                    assert (HCneq : (Permission.data, C, Block.local, 0%Z) <> (Permission.data, C_, Block.local, 0%Z))
                      by (now injection). (* Easy contradiction. *)
                    rewrite <- (Memory.load_after_store_neq _ _ _ _ _ HCneq Hmem) in Hload0.
                    erewrite <- Memory.load_after_alloc in Hload0;
                      [| exact Halloc | injection; congruence].
                    rewrite -cats2.
                    rewrite counter_value_snoc. simpl. subst prefix.
                    move: Hneq => /eqP.
                    case: ifP;
                      last now rewrite Z.add_0_r.
                    move => /eqP => Hcontra => /eqP => Hneq.
                    symmetry in Hcontra. contradiction.
                - intros Hcontra. rewrite -cats2 in Hcontra. now destruct prefix0.
                - intros pref ev Hprefix.
                  rewrite -cats2 in Hprefix.
                  apply rcons_inv in Hprefix as [? ?]; subst pref ev.
                  split.
                  + intros C_ Hcomp Hnext.
                    destruct (Nat.eqb_spec C C_) as [Heq | Hneq].
                    * subst C_.
                      rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hstore');
                        last (injection; destruct reg0; discriminate).
                      erewrite Memory.load_after_alloc;
                        [| exact Halloc | injection; congruence].
                      rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem);
                        last (injection; discriminate).
                      apply (proj1 (wfmem_extcall wf_mem Hprefix01) _ Hcomp).
                      now rewrite Hcomp1.
                    * symmetry in Hnext. contradiction.
                  + intros C_ Hcomp Hnext.
                    destruct (Nat.eqb_spec C C_) as [Heq | Hneq].
                    * subst C_. contradiction.
                    * rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hstore');
                        last (injection; destruct reg0; discriminate).
                      erewrite Memory.load_after_alloc;
                        [| exact Halloc | injection; congruence].
                      rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem);
                        last (injection; discriminate).
                      apply (proj2 (wfmem_extcall wf_mem Hprefix01) _ Hcomp).
                      intro; subst C_.
                      contradiction.
                - intros C_ reg Hcomp.
                  destruct (Nat.eqb_spec C C_) as [Heq | Hneq].
                  + subst C_.
                    destruct (EregisterP reg reg0).
                    * subst reg0.
                      (* exists (Int n). *)
                      exists saved.
                      erewrite Memory.load_after_store_eq; try reflexivity; eassumption.
                    * erewrite Memory.load_after_store_neq;
                        last eassumption;
                        last (destruct reg; destruct reg0; try discriminate; contradiction). (* This kind of reasoning on register offsets can be made into a lemma as well. *)
                      erewrite Memory.load_after_alloc;
                        [| exact Halloc | injection; congruence].
                      rewrite (Memory.load_after_store_neq _ _ _ _ _ _ Hmem);
                        last (now destruct reg).
                      eapply wfmem_meta; now eauto.
                  + destruct (wfmem_meta wf_mem reg Hcomp) as [v' Hload'].
                    exists v'.
                    erewrite Memory.load_after_store_neq;
                      last eassumption;
                      last (now injection).
                    erewrite Memory.load_after_alloc;
                      [| exact Halloc | injection; congruence].
                    erewrite Memory.load_after_store_neq;
                      try eassumption.
                    now destruct reg.
                - intros ? Hcontra. rewrite -cats2 in Hcontra. now destruct prefix0.
                - intros pref ev Hprefix.
                  rewrite -cats2 in Hprefix.
                  apply rcons_inv in Hprefix as [? ?]; subst pref ev.
                  destruct (wfmem wf_mem Hprefix01) as [Hpostregs [Hsteady Hinitial]].
                  (* rename n into n0. rename v into v0. rename Hload into Hload0. rename mem' into mem'0. *) (* rename s0 into mem'. *) (* Trying to preserve proof script... *)
                  split; [| split].
                  + {
                    (* NOTE: For simplicity, replacing some hypotheses with their available *1's *)
                    (* subst mem'. *)
                    intros n off Hoffset.
                    simpl in *.
                    (* subst v prefix. *)
                    unfold postcondition_event_registers in Hpostregs.
                    destruct (Z.eqb_spec (reg_offset reg0) off) as [Heq | Hneq].
                    - subst off.
                      assert (reg0 = reg_to_Ereg n)
                        by (now apply reg_offset_inj in Heq).
                      subst reg0.
                      (* assert (v = vptr0). { *)
                      (*   rewrite (Memory.load_after_store_eq _ _ _ _ Hstore') in Hload. *)
                      (*   now injection Hload as ?. } *)
                      (* subst v. *)
                      specialize (Hsnapshot1 _ Hb')
                        as [[cid bid] [Hshift' [Hrename Hrename']]].
                      injection Hshift' as Hcid Hbid.
                      rewrite /ssrnat.addn /ssrnat.addn_rec /ssrnat.subn /ssrnat.subn_rec
                              /all_zeros_shift /uniform_shift /= Nat.add_0_r Nat.sub_0_r
                        in Hbid.
                      subst cid bid.
                      simpl in *.

                      eexists. eexists. split; [| split].
                      * erewrite Memory.load_after_store_eq;
                          [reflexivity | exact Hstore'].
                      * rewrite /= /ssrnat.addn /ssrnat.addn_rec /ssrnat.subn /ssrnat.subn_rec
                                /= Nat.add_0_r Nat.sub_0_r.
                        reflexivity.
                      * inversion wf_int_pref' as [| | prefint eint1 eint2 Hsteps Hstep Ht];
                          [ destruct prefix; discriminate (* contra *)
                          | subst prefix; destruct prefix0 as [| ? [|]]; discriminate (* contra *)
                          | rewrite Hprefix01 in Ht;
                            symmetry in Ht; apply cats2_inv in Ht as [? [? ?]]; subst prefint eint1 eint2;
                            inversion Hstep as [| | | | | | | tmp1 tmp2 tmp3 tmp4 tmp5 tmp6];
                            subst tmp1 tmp2 tmp3 tmp4 tmp5 tmp6;
                            subst erptr].
                        rewrite Ereg_to_reg_to_Ereg Machine.Intermediate.Register.gss.
                        rewrite <- Hcomp1 in Hreg1mem0.
                        destruct (Hregs1 (Ereg_to_reg reg1) _ (f_equal _ (reg_to_Ereg_to_reg _)))
                          as [vtmp [v'' [Hload'' [Hshift'' Hget'']]]].

                        rewrite Hreg1mem0 in Hload''. injection Hload'' as ?; subst vtmp.
                        (* rewrite /= /ssrnat.addn /ssrnat.addn_rec /ssrnat.subn /ssrnat.subn_rec *)
                        (*         /= Nat.add_0_r Nat.sub_0_r *)
                        (*   in Hshift''. *)
                        injection Hshift'' as ?; subst v''.

                        rewrite Hget'' in H. injection H as ?; subst size.
                        rewrite Halloc' in H10. injection H10 as ?; subst ptr0.
                        reflexivity.

                    - setoid_rewrite Hcomp1 in Hregs1.
                      destruct (wfmem_meta wf_mem (reg_to_Ereg n) C_b)
                        as [v' Hload'].
                      rewrite Hoffset in Hload'.
                      destruct (Hregs1 n _ Logic.eq_refl) as [v [v'' [Hload [Hshift' Hget']]]].
                      assert (v = v'). {
                        subst off. rewrite Hload' in Hload. now injection Hload.
                      }
                      subst v'.
                      eexists. eexists.
                      split; [| split].
                      -- erewrite Memory.load_after_store_neq;
                           last exact Hstore';
                           last (subst off; injection; now destruct n).
                         erewrite Memory.load_after_alloc;
                           [| exact Halloc | injection; congruence].
                         erewrite Memory.load_after_store_neq;
                           last exact Hmem;
                           last (subst off; injection; now destruct n).
                         exact Hload'.
                      -- eassumption.
                      -- inversion wf_int_pref' as [| | prefint eint1 eint2 Hsteps Hstep Ht].
                         ++ destruct prefix; discriminate. (* contra *)
                         ++ subst prefix. destruct prefix0 as [| ? [ | ]]; discriminate. (* contra *)
                         ++ rewrite Hprefix01 in Ht.
                            symmetry in Ht. apply cats2_inv in Ht as [? [? ?]]. subst prefint eint1 eint2.
                            inversion Hstep as [| | | | | | | tmp1 tmp2 tmp3 tmp4 tmp5 tmp6];
                              subst tmp1 tmp2 tmp3 tmp4 tmp5 tmp6.
                            subst erptr.
                            rewrite Machine.Intermediate.Register.gso;
                              first exact Hget'.
                            destruct n; destruct reg0; try discriminate; contradiction.
                  }
                  + intros C' _ ?; subst C'. simpl.
                    specialize (Hsteady _ C_b (Logic.eq_sym Hcomp1))
                      as [Hinitflag [Hlocalbuf [Hsnapshot Hnextblock]]].
                    split; [| split; [| split]].
                    (* The first two sub-goals are near-identical arguments on
                     memory operations. *)
                    * erewrite Memory.load_after_store_neq;
                      last exact Hstore';
                      last (injection; now destruct reg0).
                      erewrite Memory.load_after_alloc;
                        [| exact Halloc | injection; discriminate].
                      erewrite Memory.load_after_store_neq;
                        last exact Hmem;
                        last (injection; now destruct reg0).
                      exact Hinitflag.
                    * erewrite Memory.load_after_store_neq;
                        last exact Hstore';
                        last (injection; now destruct reg0).
                      erewrite Memory.load_after_alloc;
                        [| exact Halloc | injection; discriminate].
                      erewrite Memory.load_after_store_neq;
                        last exact Hmem;
                        last (injection; now destruct reg0).
                      exact Hlocalbuf.
                    (* ... *)
                    * intros b Hb. simpl.
                      specialize (Hsnapshot b Hb) as [[cid bid] [Hshift' [Hrename Hrename']]].
                      destruct b as [| b']; first discriminate.
                      rewrite shift_S_Some in Hshift'.
                      injection Hshift' as ? ?; subst cid bid.
                      exists (C, b'). split; [| split].
                      -- rewrite shift_S_Some.
                         reflexivity.
                      -- simpl. intros off v' Hload'.
                         erewrite Memory.load_after_store_neq in Hload';
                           last exact Hstore';
                           last (injection; congruence).
                         destruct (Nat.eqb_spec (S b') (S bptr)) as [Heq | Hneq].
                         ++ injection Heq as ?; subst b'.
                            erewrite Memory.load_after_alloc_eq in Hload';
                              [| exact Halloc | reflexivity].
                            simpl in Hload'.
                            destruct (off <? Z.of_nat (Z.to_nat n1))%Z eqn:Hoff1;
                              last discriminate.
                            destruct (0 <=? off)%Z eqn:Hoff2;
                              last discriminate.
                            injection Hload' as ?; subst v'.
                            eexists. split; last reflexivity.
                            by rewrite (Memory.load_after_alloc_eq _ _ _ _ _ (_, _, _, off) Halloc' Logic.eq_refl) /= Hoff1 Hoff2 //.
                         ++ erewrite Memory.load_after_alloc in Hload';
                              [| exact Halloc | injection; congruence].
                            erewrite Memory.load_after_store_neq in Hload';
                              last exact Hmem;
                              last (injection; congruence).
                            simpl in Hrename.
                            specialize (Hrename off v' Hload') as [v'' [Hload'' Hrename'']].
                            exists v''. split; last congruence.
                            erewrite Memory.load_after_alloc;
                              [| exact Halloc' | injection; congruence].
                            exact Hload''.
                      -- simpl. intros off v' Hload'.
                         simpl in Hrename'.
                         destruct (Nat.eqb_spec b' bptr) as [Heq | Hneq].
                         ++ subst b'.
                            erewrite Memory.load_after_alloc_eq in Hload';
                              [| exact Halloc' | reflexivity].
                            simpl in Hload'.
                            eexists. split.
                            ** erewrite Memory.load_after_store_neq;
                                 last exact Hstore';
                                 last (injection; discriminate).
                               erewrite Memory.load_after_alloc_eq;
                                 [| exact Halloc | reflexivity].
                               simpl.
                               exact Hload'.
                            ** destruct (off <? Z.of_nat (Z.to_nat n1))%Z; last discriminate.
                               destruct (0 <=? off)%Z; last discriminate.
                               injection Hload' as ?; subst v'.
                               now constructor.
                         ++ erewrite Memory.load_after_alloc in Hload';
                              [| exact Halloc' | injection; contradiction].
                            specialize (Hrename' _ _ Hload') as [v'' [Hload'' Hrename']].
                            eexists. split.
                            ** erewrite Memory.load_after_store_neq;
                                 last exact Hstore';
                                 last (injection; discriminate).
                               erewrite Memory.load_after_alloc;
                                 [| exact Halloc | injection; contradiction].
                               erewrite Memory.load_after_store_neq;
                                 last exact Hmem;
                                 last (injection; discriminate).
                               exact Hload''.
                            ** exact Hrename'.

                    * intros next Hnext.
                      rewrite Hnexts0 in Hnext.
                      injection Hnext as ?; subst next.
                      erewrite Memory.next_block_store_stable;
                        last exact Hstore'.
                      exact Hnextmem'.
                  + intros C' Hcomp Hnext.
                    rewrite <- Hcomp1 in Hnext.
                    specialize (Hinitial _ Hcomp Hnext) as [Hsteady' | Hinitial].
                    * destruct Hsteady' as [Hinitflag [Hlocalbuf Hsteady']].
                      left. split; [| split].
                      -- erewrite Memory.load_after_store_neq;
                           last exact Hstore';
                           last (injection; now destruct reg0).
                         erewrite Memory.load_after_alloc;
                           [| exact Halloc | injection; now destruct reg0].
                         erewrite Memory.load_after_store_neq;
                           last exact Hmem;
                           last (injection; now destruct reg0).
                         exact Hinitflag.
                      -- erewrite Memory.load_after_store_neq;
                           last exact Hstore';
                           last (injection; now destruct reg0).
                         erewrite Memory.load_after_alloc;
                           [| exact Halloc | injection; now destruct reg0].
                         erewrite Memory.load_after_store_neq;
                           last exact Hmem;
                           last (injection; now destruct reg0).
                         exact Hlocalbuf.
                      -- destruct Hsteady' as [Hsnapshot Hnextblock].
                         split.
                         ++ intros b Hlocal.
                            specialize (Hsnapshot b Hlocal) as [[cid bid] [Hshift' [Hrename Hrename']]].
                            destruct b as [| b']; first discriminate.
                            rewrite shift_S_Some in Hshift'.
                            injection Hshift' as ? ?; subst cid bid.
                            exists (C', b'). split; [| split].
                            ** rewrite shift_S_Some. reflexivity.
                            ** intros off v' Hload.
                               erewrite Memory.load_after_store_neq in Hload;
                                 last exact Hstore';
                                 last (injection; discriminate).
                               erewrite Memory.load_after_alloc in Hload;
                                 [| exact Halloc |];
                                 last (injection as ? ?; subst C' b';
                                       apply Hnext;
                                       now rewrite Hcomp1).
                               erewrite Memory.load_after_store_neq in Hload;
                                 last exact Hmem;
                                 last (injection; congruence).
                               specialize (Hrename off v' Hload) as [v'' [Hload'' Hrename]].
                               eexists. split.
                               --- erewrite Memory.load_after_alloc;
                                     [| exact Halloc' | simpl in *; injection; congruence].
                                   exact Hload''.
                               --- exact Hrename.
                            ** intros off v' Hload.
                               (* subst mem'. *)
                               (* simpl in *. *)
                               (* NOTE: Also in sub-case above! *)
                               simpl in Hload.
                               erewrite Memory.load_after_alloc in Hload;
                                 [| exact Halloc' | simpl in *; injection; congruence].
                               specialize (Hrename' _ _ Hload) as [v'' [Hload' Hrename']].
                               eexists. split.
                               --- erewrite Memory.load_after_store_neq;
                                     last exact Hstore';
                                     last (injection; congruence).
                                   erewrite Memory.load_after_alloc;
                                     [| exact Halloc | simpl in *; injection; congruence].
                                   erewrite Memory.load_after_store_neq;
                                     last exact Hmem;
                                     last (injection; congruence).
                                   exact Hload'.
                               --- exact Hrename'.
                         ++ (* Here the second proof on next block differs! *)
                           intros next Hnext'.
                           erewrite Memory.next_block_store_stable;
                             last exact Hstore'.
                           rewrite Hcomp1 in Hnext.
                           rewrite (Memory.next_block_alloc_neq _ _ _ _ _ _ Halloc Hnext).
                           erewrite Memory.next_block_store_stable;
                             last exact Hmem.
                           erewrite Memory.next_block_alloc_neq in Hnext';
                             [| exact Halloc' | exact Hnext].
                           apply Hnextblock.
                           exact Hnext'.
                    * right.
                      destruct Hinitial as [Hinitflag [Hlocalbuf [Hinitial Hnot_shared]]].
                      split; [| split; [| split]].
                      -- erewrite Memory.load_after_store_neq;
                           last exact Hstore';
                           last (injection; now destruct reg0).
                         erewrite Memory.load_after_alloc;
                           [| exact Halloc | injection; discriminate].
                         erewrite Memory.load_after_store_neq;
                           last exact Hmem;
                           last (injection; now destruct reg0).
                         exact Hinitflag.
                      -- erewrite Memory.load_after_store_neq;
                           last exact Hstore';
                           last (injection; now destruct reg0).
                         erewrite Memory.load_after_alloc;
                           [| exact Halloc | injection; discriminate].
                         erewrite Memory.load_after_store_neq;
                           last exact Hmem;
                           last (injection; now destruct reg0).
                         exact Hlocalbuf.
                      -- destruct Hinitial as [Hprealloc Hnextblock].
                         split.
                         ** destruct Hprealloc
                              as [Cmem [buf [HCmem [Hbuf [Hnextblock' Hprealloc]]]]].
                            exists Cmem, buf.
                            split; [| split; [| split]]; try assumption.
                            rewrite -HCmem. symmetry.
                            eapply component_memory_after_alloc_neq; eauto.
                            rewrite -Hcomp1. exact Hnext.
                         ** destruct Hnextblock as [Cmem [HCmem Hnextblock]].
                            exists Cmem. split; last assumption.
                            rewrite -HCmem. symmetry.
                            transitivity (mem C'); [| transitivity (mem' C')].
                            --- eapply component_memory_after_store_neq; eauto.
                                intro Hcontra. apply Hnext. rewrite -Hcontra. easy.
                            --- eapply component_memory_after_alloc_neq; eauto.
                                rewrite -Hcomp1. exact Hnext.
                            --- eapply component_memory_after_store_neq; eauto.
                                intro Hcontra. apply Hnext. rewrite -Hcontra. easy.
                      -- by rewrite -cats1 project_non_inform_append /= E0_right cats1.
                - move=> ptr cid bid off.
                  destruct (Pointer.eq ptr (Permission.data, cur_comp s, Block.local, reg_offset reg0)) eqn:eq_ptr;
                    move: eq_ptr =>
                             /Pointer.eqP eq_ptr; subst;
                             [erewrite Memory.load_after_store_eq; eauto; try by []
                             | erewrite Memory.load_after_store_neq; eauto; clear eq_ptr].
                  unfold saved. intros R; inversion R; by [].
                  destruct ptr as [[[[]]]]; try by [].
                  destruct (i == cur_comp s) eqn:eC; move: eC => /eqP eC; subst.
                  destruct (i0 == S bptr) eqn:eB; move: eB => /eqP eB; subst.
                  erewrite Memory.load_after_alloc_eq; eauto. simpl.
                  case: ifP => ?. case: ifP => R; inversion R; by [].
                  by [].
                  erewrite Memory.load_after_alloc; eauto. simpl.
                  unfold C in *.
                  destruct (Pointer.eq (Permission.data, cur_comp s, i0, o)
                                       (Permission.data, cur_comp s, Block.local, 0%Z)) eqn:eq_ptr;
                    move: eq_ptr =>
                             /Pointer.eqP eq_ptr; try inversion eq_ptr; subst;
                             [erewrite Memory.load_after_store_eq; eauto; try by []
                             | erewrite Memory.load_after_store_neq; eauto; clear eq_ptr].
                  by eapply wfmem_no_private_ptr; eauto.
                  simpl. congruence.
                  erewrite Memory.load_after_alloc; eauto. simpl.
                  unfold C in *.
                  erewrite Memory.load_after_store_neq; eauto.
                  eapply wfmem_no_private_ptr; eauto.
                  by congruence. simpl; by congruence.
              }
            + simpl.
              rewrite -cats2 project_non_inform_append /=.
              rewrite -> !cats0, <- Hprefix01.
              by inversion Hshift; eauto.
        }

        destruct Star2 as (e' & s' & cs' & Star2 & wf_cs' & Hshift').
        (* TODO: The statement needs to be extended to relate e and e'! *)
        (* NOTE: Now, case analysis on the event needs to take place early. *)
        exists cs', s',
          (prefix_inform ++ [:: e']), (prefix' ++ project_non_inform [:: e']).
        split; [| split; [| split]].
        + eapply (star_trans Star0); simpl; eauto.
          eapply (star_trans Star1); simpl; now eauto.
        + by rewrite -Hproj project_non_inform_append.
        + constructor.
          exact Hshift'.
        + assumption.
          Unshelve. all:(unfold Block.local; try congruence).
          all: auto.
    Qed.

    Print Assumptions definability_gen_rel_right.

    Lemma definability :
      forall procs, (* NOTE: procs plays a limited role here *)
        @well_formed_trace T intf procs t ->
        well_formed_intermediate_prefix t ->
        exists s' t' const_map,
          Star (CS.sem p) (CS.initial_machine_state p) t' s' /\
            (* program_behaves (CS.sem p) (Terminates t') /\ *)
            traces_shift_each_other_option
              (* metadata_size_lhs *)
              all_zeros_shift
              const_map
              (project_non_inform t)
              t' /\
            const_map = uniform_shift 1.
    Proof.
      move=> procs /andP [] wb_t _ wf_i_t.
      pose proof (@definability_gen_rel_right t [::] wb_t wf_i_t
                                              (Logic.eq_sym (app_nil_r _))).
      destruct H as [cs [s [pref_inform [t' [Hstar [Hproj [Htraces [Hwf Hleak]]]]]]]].
      exists cs. exists t'. exists (uniform_shift 1).
      split. eauto. split. eauto. eauto.
    Qed.

  End WithTrace.
End Definability.

