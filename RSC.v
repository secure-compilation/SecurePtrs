Require Import CompCert.Behaviors.
Require Import CompCert.Smallstep.
Require Import Common.Definitions.
Require Import Common.Linking.
Require Import Common.CompCertExtensions.
Require Import Common.TracesInform.
Require Import Common.RenamingOption.

Require Import Source.Definability.
Require Import Source.DefinabilityEnd.
Require Import Source.Language.
Require Import Source.GlobalEnv.
Require Import Source.CS.
Require Import Intermediate.Machine.
Require Import Intermediate.CS.
Require Import Intermediate.RecompositionRel.
Require Import S2I.Compiler.
Require Import S2I.Definitions.


From mathcomp Require Import ssreflect ssrfun ssrbool.

Set Implicit Arguments.
Unset Strict Implicit.

Set Bullet Behavior "Strict Subproofs".

Section RSC_Section.
  Variable p: Source.program.
  Variable psz: {fmap Component.id -> nat}.
  Variable p_compiled: Intermediate.program.
  Variable Ct: Intermediate.program.

  (* Some reasonable assumptions about our programs *)

  Hypothesis domm_psz_intf: domm psz = domm (Source.prog_interface p).
  Hypothesis well_formed_p : Source.well_formed_program p.
  Hypothesis disciplined_p: Compiler.disciplined_program p.
  Hypothesis good_Elocal_p: NoLeak.good_Elocal_usage_program p.
  Hypothesis successful_compilation : Compiler.compile_program p psz = Some p_compiled.
  Hypothesis well_formed_Ct : Intermediate.well_formed_program Ct.
  Hypothesis linkability : linkable (Source.prog_interface p) (Intermediate.prog_interface Ct).
  Hypothesis closedness :
    Intermediate.closed_program (Intermediate.program_link p_compiled Ct).
  Hypothesis mains : Intermediate.linkable_mains p_compiled Ct.

  (* Main Theorem *)


  (* [DynShare]
     
     - Maybe we can get rid of the disjunction "... \/ behavior_improves_blame beh".
     - And also we should (instead of program_behaves) directly use 
       does_prefix (Source.CS.sem (Source.program_link p Cs)) m' 
       Notice that does_prefix is the "finite version" of "program_behaves", i.e., it still
       contains the cases of FTerminates and FGoesWrong.

     * Because our current S2I compiler does not seem to refine any undef behavior,
       we should be able to get rid of the blame disjunct.

   *)

  Theorem RSC:
    forall t s,
      Star (Intermediate.CS.CS.sem_non_inform (Intermediate.program_link p_compiled Ct))
           (Intermediate.CS.CS.initial_machine_state
              (Intermediate.program_link p_compiled Ct)
           )
           t
           s
      ->
      exists Cs t' s' size_meta size_meta',
      Source.prog_interface Cs = Intermediate.prog_interface Ct /\
      Source.well_formed_program Cs /\
      linkable (Source.prog_interface p) (Source.prog_interface Cs) /\
      Source.closed_program (Source.program_link p Cs) /\
      Star (Source.CS.CS.sem (Source.program_link p Cs))
           (Source.CS.CS.initial_machine_state
              (Source.program_link p Cs)
           )
           t'
           s'
      /\
      traces_shift_each_other_option size_meta size_meta' t t'.
  Proof.
    intros t s Hstar.

    (* Some auxiliary results. *)
    pose proof
      Compiler.compilation_preserves_well_formedness well_formed_p successful_compilation
      as well_formed_p_compiled.

    assert (linkability_pcomp_Ct :
              linkable (Intermediate.prog_interface p_compiled)
                       (Intermediate.prog_interface Ct)).
    {
      assert (sound_interface_p_Ct : sound_interface (unionm (Source.prog_interface p)
                                                             (Intermediate.prog_interface Ct)))
        by apply linkability.
      assert (fdisjoint_p_Ct : fdisjoint (domm (Source.prog_interface p))
                                         (domm (Intermediate.prog_interface Ct)))
        by apply linkability.
      constructor;
        apply Compiler.compilation_preserves_interface in successful_compilation;
        now rewrite successful_compilation.
    }

    assert (exists t_inform,
               Star
                 (Intermediate.CS.CS.sem_inform
                    (Intermediate.program_link p_compiled Ct))
                 (Intermediate.CS.CS.initial_machine_state
                    (Intermediate.program_link p_compiled Ct)
                 )
                 t_inform
                 s
               /\ project_non_inform t_inform = t) as [t_inform [Hstarinform Hproj]].
    {
      by eapply Intermediate.CS.CS.star_sem_non_inform_star_sem_inform.
    }

    

    (* definability *)
    destruct (definability_with_linking
                well_formed_p_compiled
                well_formed_Ct
                linkability_pcomp_Ct
                closedness
                Hstarinform)
      as [P' [Cs [t' [s' [metadata_size
         [Hsame_iface1 [Hsame_iface2
         [Hmatching_mains_P'_p_compiled [Hmatching_mains_Cs_Ct
                                           [well_formed_P' [well_formed_Cs [HP'Cs_closed [Hstar' [Ht_rel_t' [Hconst_map [good_P'_Cs [P'_Cs_disciplined P'_CS_good_Elocal]]]]]]]]]]]]]]]]].

    assert (Source.linkable_mains P' Cs) as HP'Cs_mains.
    { apply Source.linkable_disjoint_mains; trivial; congruence. }

    
    (* FCC *)

    (* the definability output can be split in two programs *)
    (* probably need partialize to obtain them *)

    (* At this point, we compile P' and Cs and establish their basic properties. *)
    
    have well_formed_P'Cs : Source.well_formed_program (Source.program_link P' Cs).
      rewrite -Hsame_iface1 -Hsame_iface2 in linkability_pcomp_Ct.
      exact: Source.linking_well_formedness well_formed_P' well_formed_Cs linkability_pcomp_Ct.

      assert (P'Cs_disciplined: disciplined_program (Source.program_link P' Cs)).
      {
        intros ? ? ? Hfind.
        eapply P'_Cs_disciplined; eauto.
      }
      
      assert (exists s' t'compiled P'Cs_sz P'_Cs_compiled,
                 domm P'Cs_sz = domm (Source.prog_interface (Source.program_link P' Cs))
                 /\
                 Compiler.compile_program (Source.program_link P' Cs) P'Cs_sz =
                 Some P'_Cs_compiled
                 /\
                 Star (Intermediate.CS.CS.sem_non_inform P'_Cs_compiled)
                      (I.CS.initial_machine_state P'_Cs_compiled)
                      t'compiled s'
                 /\
                 traces_shift_each_other_option
                   (uniform_shift 1)
                   (uniform_shift 1)
                   t'
                   t'compiled
             )
        as [s'_compiled [t'compiled [P'Cs_sz [P'_Cs_compiled
                                       [Hdomm_P'Cs_sz
                                          [HP'_Cs_compiles
                                             [HP'_Cs_compiled_star
                                                Ht'_rel_t'compiled

           ]]]]]]].
      {
        eapply Compiler.forward_simulation_star with (metasize := uniform_shift 1).
        - assumption.
        - assumption.
        - exact P'Cs_disciplined.
        - exact P'_CS_good_Elocal.
        - exact Hstar'.
      }


    assert (P'_Cs_linkable:
              linkable (Source.prog_interface P') (Source.prog_interface Cs)).
    {
      by rewrite Hsame_iface1 Hsame_iface2.
    }

    assert (exists P'sz Cssz,
               unionm P'sz Cssz = P'Cs_sz 
           ) as [P'sz [Cssz Hunion]].
    {
      exists (filterm (fun k => fun=> k \in domm (Source.prog_interface P')) P'Cs_sz).
      exists (filterm (fun k => fun=> k \in domm (Source.prog_interface Cs)) P'Cs_sz).
      assert (G': unionm
                    (filterm (T:=nat_ordType)
                             (fun k : nat_ordType =>
                                fun=> k \in domm
                                              (T:=nat_ordType)
                                              (S:=Component.interface)
                                              (Source.prog_interface P'))
                             P'Cs_sz)
                    (filterm (T:=nat_ordType)
                             (fun k : nat_ordType =>
                                fun=> k \in domm
                                              (T:=nat_ordType)
                                              (S:=Component.interface)
                                              (Source.prog_interface Cs))
                             P'Cs_sz) = P'Cs_sz).
      {
        apply eq_fmap. intros x. rewrite unionmE !filtermE.
        
        destruct (P'Cs_sz x) eqn:e.
        + simpl.
          assert (G1: exists n, P'Cs_sz x = Some n) by eauto.
          move : G1 => /dommP => G1.
          rewrite Hdomm_P'Cs_sz domm_union in G1.
          destruct (x \in domm (Source.prog_interface P')) eqn:edomm; rewrite edomm;
            simpl; auto.
          assert (x \in domm (Source.prog_interface Cs)).
          {
            rewrite in_fsetU in G1.
            move : G1 => /orP => G1.
            destruct G1 as [contra|G1]; [by rewrite edomm in contra | assumption].
          }
            by rewrite H.
        + by simpl.
      }
      exact G'.
    }

    specialize (Compiler.well_formed_compilable _ P'sz well_formed_P') as
        [P'_compiled HP'_compiles].

    specialize (Compiler.well_formed_compilable _ Cssz well_formed_Cs) as
        [Cs_compiled HCs_compiles].
    rewrite -Hunion in HP'_Cs_compiles.

    assert (Hrewr: compile_program (Source.program_link P' Cs) (unionm P'sz Cssz) =
                   Some (Intermediate.program_link P'_compiled Cs_compiled)).
    { by eapply Compiler.separate_compilation; eauto. }

    rewrite HP'_Cs_compiles in Hrewr.
    inversion Hrewr. subst.
      
        
    pose proof Compiler.compilation_preserves_well_formedness well_formed_P' HP'_compiles
      as well_formed_P'_compiled.
    
    pose proof Compiler.compilation_preserves_well_formedness well_formed_Cs HCs_compiles
      as well_formed_Cs_compiled.


    assert
      (linkable
         (Intermediate.prog_interface Cs_compiled)
         (Intermediate.prog_interface P'_compiled))
      as linkability'. {
      eapply @Compiler.compilation_preserves_linkability with (p:=Cs) (c:=P'); eauto.
      apply linkable_sym.
      rewrite <- Hsame_iface1 in linkability_pcomp_Ct.
      rewrite <- Hsame_iface2 in linkability_pcomp_Ct.
      apply linkability_pcomp_Ct.
    }
    
    rewrite Intermediate.program_linkC in HP'_Cs_compiled_star;
       [| assumption |assumption | apply linkable_sym in linkability'; assumption].

    (* intermediate composition *)
    assert (Intermediate.prog_interface Ct = Intermediate.prog_interface Cs_compiled)
      as Hctx_same_iface. {
      symmetry. erewrite Compiler.compilation_preserves_interface.
      - rewrite <- Hsame_iface2. reflexivity.
      - eassumption.
    }
    (* rewrite Hctx_same_iface in HP_decomp. *)
    assert (Intermediate.prog_interface p_compiled = Intermediate.prog_interface P'_compiled) as Hprog_same_iface. {
      symmetry. erewrite Compiler.compilation_preserves_interface.
      - apply Hsame_iface1.
      - eassumption.
    }
    (* rewrite <- Hprog_same_iface in HCs_decomp. *)

    assert (linkable (Intermediate.prog_interface p_compiled) (Intermediate.prog_interface Cs_compiled))
      as linkability''.
    {
      unfold linkable. split; try
        rewrite Hprog_same_iface;
        apply linkable_sym in linkability';
        now inversion linkability'.
    }
    assert (Intermediate.closed_program (Intermediate.program_link p_compiled Cs_compiled))
      as HpCs_compiled_closed.
    pose proof S2I.Definitions.matching_mains_equiv
         _ _ _
         Hmatching_mains_Cs_Ct
         (Compiler.compilation_has_matching_mains well_formed_Cs HCs_compiles)
         as Hctx_match_mains.
    now apply (Intermediate.interface_preserves_closedness_r
                 well_formed_p_compiled well_formed_Cs_compiled
                 Hctx_same_iface linkability_pcomp_Ct closedness mains Hctx_match_mains); auto.
    assert (Intermediate.well_formed_program (Intermediate.program_link p_compiled Cs_compiled))
      as HpCs_compiled_well_formed
        by (apply Intermediate.linking_well_formedness; assumption).

    assert (Intermediate.linkable_mains p_compiled Cs_compiled) as linkable_mains.
    {
      eapply (@Compiler.compilation_preserves_linkable_mains p _ _ Cs);
        try eassumption.
      - rewrite <- Hsame_iface2 in linkability.
        eapply Source.linkable_disjoint_mains; assumption.
    }

    assert (mergeable_interfaces (Intermediate.prog_interface p_compiled)
                                 (Intermediate.prog_interface Cs_compiled))
      as Hmergeable_ifaces.
      by apply Intermediate.compose_mergeable_interfaces.

    assert (Source.closed_program (Source.program_link p Cs)) as Hclosed_p_Cs. {
      apply (Source.interface_preserves_closedness_l HP'Cs_closed); trivial.
      apply Compiler.compilation_preserves_interface in HP'_compiles.
      apply Compiler.compilation_preserves_interface in successful_compilation.
      congruence.
    }
    assert (linkable (Source.prog_interface p) (Source.prog_interface Cs))
      as Hlinkable_p_Cs. {
      inversion linkability'' as [sound_interface_p_Cs fdisjoint_p_Cs].
      constructor;
        (apply Compiler.compilation_preserves_interface in HCs_compiles;
        apply Compiler.compilation_preserves_interface in successful_compilation;
        rewrite <- HCs_compiles; rewrite <- successful_compilation;
        assumption).
    }
    assert (Source.well_formed_program (Source.program_link p Cs)) as Hwf_p_Cs
      by (apply Source.linking_well_formedness; assumption).

    assert (HP'Cs_compiled_closed :
              Intermediate.closed_program (Intermediate.program_link P'_compiled Cs_compiled)).
    {
      rewrite Intermediate.program_linkC; try easy; try now apply linkable_sym.
      apply Intermediate.interface_preserves_closedness_r with (p2 := p_compiled); eauto.
      apply linkable_sym; eauto.
      rewrite Intermediate.program_linkC; eauto.
      apply linkable_sym; eauto.
      apply Intermediate.linkable_mains_sym; eauto.
      eapply S2I.Definitions.matching_mains_equiv; eauto.
      eapply Compiler.compilation_has_matching_mains; eauto.
    }

    rewrite Intermediate.program_linkC in HP'_Cs_compiled_star; try assumption.
    rewrite <- Hctx_same_iface in Hmergeable_ifaces.

    assert (H_p_Ct_good: forall (ss : CS.state) (tt : Events.trace Events.event),
               CSInvariants.CSInvariants.is_prefix
                 ss (Intermediate.program_link p_compiled Ct) tt ->
               good_trace_extensional (left_addr_good_for_shifting all_zeros_shift) tt
               /\
               (forall (mem : eqtype.Equality.sort Memory.Memory.t) (ptr : Pointer.t)
                       (addr : Component.id * Block.id) (v : value),
                   CS.state_mem ss = mem ->
                   Memory.Memory.load mem ptr = Some v ->
                   addr = (Pointer.component ptr, Pointer.block ptr) ->
                   left_addr_good_for_shifting all_zeros_shift addr ->
                   left_value_good_for_shifting all_zeros_shift v)).
    {
      intros ? ? ?. split.
      - constructor. intros ? ?. destruct a as [? ?].
        unfold all_zeros_shift, uniform_shift. easy.
      - intros ? ? ? ? ? ? ? ?.
        destruct v as [| [[[[|] ?] ?] ?] |]; unfold all_zeros_shift, uniform_shift;
          simpl; easy.
    }

    (** Need an axiom about the Compiler. The axiom will transfer goodness of *)
    (** a source program to goodness of the compiled version, where goodness  *)
    (** is described as conformance of the sharing behavior with the static   *)
    (** address renaming convention (i.e., shared addresses are renamed into  *)
    (** shared addresses). Viewed dually, the axiom about the compiler says   *)
    (** that the compiler preserves the privacy of private (non-shared)       *) 
    (** addresses.                                                            *)

    (** With such an axiom in hand, we can assert the following from its      *)
    (** corresponding source version.                                         *)

    assert (HP'_compiled_Cs_compiled_good: forall (ss'' : CS.state) tt'',
               CSInvariants.CSInvariants.is_prefix
                 ss''
                 (Intermediate.program_link P'_compiled Cs_compiled) tt'' ->
               good_trace_extensional
                 (left_addr_good_for_shifting
                    (uniform_shift 1)) tt''
               /\
               (forall (mem : eqtype.Equality.sort Memory.Memory.t) (ptr : Pointer.t)
                       (addr : Component.id * Block.id) (v : value),
                   CS.state_mem ss'' = mem ->
                   Memory.Memory.load mem ptr = Some v ->
                   addr = (Pointer.component ptr, Pointer.block ptr) ->
                   left_addr_good_for_shifting
                     (uniform_shift 1) addr ->
                   left_value_good_for_shifting
                     (uniform_shift 1) v)).
    {
      assert (P'_Cs_closed: Source.closed_program (Source.program_link P' Cs)).
      {
        eapply Source.interface_preserves_closedness_l; eauto.
        rewrite Hsame_iface1.
        erewrite compilation_preserves_interface; eauto.
      }

      assert (P'_Cs_wf: Source.well_formed_program (Source.program_link P' Cs)).
      {
        eapply Source.linking_well_formedness; eauto.
      }
      
      specialize (Compiler.compiler_preserves_non_leakage_of_private_pointers
                    _ _ _ _ P'_Cs_closed P'_Cs_wf HP'_Cs_compiles good_P'_Cs
                 ) as G.
      unfold CSInvariants.CSInvariants.is_prefix.
      intros ? ? Hpref.
      unfold private_pointers_never_leak_I, shared_locations_have_only_shared_values in *.
      specialize (G ss'' tt'' Hpref) as [G1 G2].
      split; first exact G1.
      intros ? ? ? ? ? ? ? ?.
      eapply G2; eauto.
    }

    assert (t_rel_t'compiled: traces_shift_each_other_option
                        all_zeros_shift
                        (uniform_shift 1)
                        (project_non_inform t_inform) t'compiled).
    {
        eapply traces_shift_each_other_option_transitive.
        - apply traces_shift_each_other_option_symmetric; exact Ht_rel_t'.
        - exact Ht'_rel_t'compiled.
    }

    
    pose proof Intermediate.RecompositionRel.recombination_trace_rel
    well_formed_p_compiled
    well_formed_Ct
    well_formed_P'_compiled
    well_formed_Cs_compiled
    Hmergeable_ifaces
    Hprog_same_iface
    Hctx_same_iface
    closedness
    HP'Cs_compiled_closed
    H_p_Ct_good
    HP'_compiled_Cs_compiled_good
    Hstar
    HP'_Cs_compiled_star
    t_rel_t'compiled
      as [s_recomb [t_recomb [Hstar_recomb [_ trel_recomb]]]].

    
    (* BCC *)
    assert (exists pCs_compiled,
               Compiler.compile_program (Source.program_link p Cs)
                                        (unionm psz Cssz)
               = Some pCs_compiled)
      as [pCs_compiled HpCs_compiles].
      by now apply Compiler.well_formed_compilable.
      
      eapply Compiler.backward_simulation_star
        in Hstar_recomb
      ;
        eauto;
        last by
        (erewrite HpCs_compiles;
         erewrite Compiler.separate_compilation in HpCs_compiles; eauto
        ).
      
      destruct Hstar_recomb as [s'_pCs HpCs_star].
      destruct HpCs_star as [tQed [HstarQed HshiftQed]].
      do 5 eexists; split; last split; last split; last split; last split;
        eauto.
      {
        eapply traces_shift_each_other_option_transitive.
        - exact trel_recomb.
        - eassumption.
      }
      
      apply disciplined_program_link; auto.
      
      eapply disciplined_program_unlink with (c := P'); eauto.
      - eapply linkable_sym. eauto.
      - rewrite Source.link_sym; auto.
        by apply linkable_sym.
      - eapply NoLeak.good_Elocal_usage_program_link; auto.
        eapply NoLeak.good_Elocal_usage_program_unlink with (c := P'); eauto.
        eapply linkable_sym; eauto.
        rewrite Source.link_sym; auto.
        by apply linkable_sym.
Qed.

Print Assumptions RSC.

End RSC_Section.

(* To evaluate the assumptions and statements of the main results,
   uncomment and execute the following statements. To show the
   statement of a theorem, replace [Print Assumptions] -> [Check]. *)

(* Check RSC. *)
(* Print Assumptions S2I.Compiler.forward_simulation_star. *)
(* Print Assumptions Intermediate.RecompositionRel.recombination_trace_rel. *)
(* Print Assumptions S2I.Compiler.backward_simulation_star. *)
(* Print CompCert.Events.event. *)
(* Print Common.TracesInform.event_inform. *)
(* Print Assumptions Intermediate.CS.CS.star_sem_non_inform_star_sem_inform. *)
(* Print Assumptions Source.Definability.definability. *)
(* Print Intermediate.RecompositionRelCommon.mergeable_internal_states. *)
(* Print Common.RenamingOption.traces_shift_each_other_option. *)
(* Check Intermediate.CS.CS.Jump. *)
(* Check Intermediate.CS.CS.Store. *)
(* Print Assumptions RSC. *)
(* Print Assumptions Source.Definability.definability_gen_rel_right. *)
(* Print Intermediate.RecompositionRelCommon.mergeable_border_states. *)
(* Print Assumptions Intermediate.RecompositionRelStrengthening.threeway_multisem_event_lockstep_program_step. *)
(* Print Assumptions Intermediate.RecompositionRelOptionSim.merge_states_silent_star. *)
(* Print Assumptions Intermediate.RecompositionRelLockstepSim.threeway_multisem_star_E0. *)
(* Print Assumptions Intermediate.RecompositionRelCommon.mergeable_internal_states_sym. *)
