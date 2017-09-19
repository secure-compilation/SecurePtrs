Require Import CompCert.Events.
Require Import CompCert.Smallstep.
Require Import CompCert.Behaviors.
Require Import Coq.Lists.List.
Require Import Coq.Program.Basics.
Require Import Common.Definitions.
Require Import Common.Linking.
Require Import Intermediate.Machine.
Require Import Intermediate.CS.
Require Import Intermediate.PS.

(* 
   Full proof of robust compilation relying on 
   - target decomposition,
   - compiler correctness and 
   - source definability
  
   For a simple instance refer to SI.RC, a more complicate instance is
   in Main.robust_compilation_static_compromise.
 *)

(* 
   Some Global definitions.
 *)

(* Component id *)
Definition partition := list Component.id.
Definition interface := Program.interface.

(* check if the last event of a behavior belongs to an agent,
   represented by the interface of its components *)
Definition turn_trace (t:trace) (par:partition) : Prop :=
  forall e, exists t', t = e::t' /\
             (match e with
              | ECall Cid Pid n Cid' => In Cid' par
              | ERet Cid n Cid' => In Cid' par
              end).
  

(* For now turn is defined only for finite traces. *)
Definition turn (b:program_behavior) (i:partition) : Prop :=
  exists t, turn_trace t i /\
            ((exists n, b = Terminates t n) \/
            (b = Diverges t) \/
            (b = Goes_wrong t)).
             
  
(* check if an interface is complete *)
Definition icomplete := Linking.closed_interface.
(* check if the union of two interfaces is complete *)
Definition icomplete2 (i1 i2:interface) := icomplete (NMapExtra.update i1 i2).
(* check if a interface is contained in another *)
Definition contained (i1 i: interface) :=
  exists i2, NMap.Equal (NMapExtra.update i1 i2) i.


Definition behavior_improves_p (behs beht:program_behavior) (par:partition) :=
  (behs = beht \/ (exists t, behs = Goes_wrong t /\
                             behavior_prefix t beht /\
                             turn behs par)).

(* 
   The languages.
 *)

(* CH: In the end, moving valid into the program type (using a sigma
       type) might still be an option if it simplifies things and if
       no code that uses a program depends on the validity proof *)

(* Signature of basic things expected in a language *)
Module Type Lang.
  (* Type of programs, complete or partial *)
  Parameter program : Type.
  (* validity of program wrt to its interface, it's a relation between
     well-formed programs and their contained interfaces; it is
     a (not necessarily computable) partial function *)
  Parameter valid : program -> Prop.
  (* returns the interface of a program *)
  Parameter get_interface: program -> interface.

  (* The following 2 definitions are really always the same *)
  (* checks if a program has a complete interface *)
  Definition complete (p:program) :=
    valid p /\ icomplete (get_interface p).
  (* checks if two programs are valid and their interfaces are *)
  Definition complete2 (p1 p2:program) :=
    valid p1 /\ valid p2 /\
    icomplete2 (get_interface p1) (get_interface p2).

  (* CompCert defines the semantics of a program as an object providing the following:  
Record semantics : Type := Semantics_gen {
  state: Type;
  genvtype: Type;
  step : genvtype -> state -> trace -> state -> Prop;
  initial_state: state -> Prop;
  final_state: state -> int -> Prop;
  globalenv: genvtype;
}.

   any program has a semantics, if the program is ill-formed it
   still has a behavior. e.g. a program without any initial state
   satisfies program_goes_initially_wrong
   *)
  
  (* produces a complete semantics from a complete program *)
  Parameter sem: program -> semantics.
  
  (* produces a partial semantics from a complete program and an
     interface that is contained in it. The components of this interface
     will be ignored. *)
  (* TODO we should check that program is complete and interface is contained *)
  Parameter psem: interface -> program -> semantics.

  (* Parameter val : Type. *)
  (* Record CoreSemantics {G C M : Type} : Type := *)
  (* { initial_core : G -> val -> list val -> option C *)
  (* ; at_external : C -> option (external_function * signature * list val) *)
  (* ; after_external : val -> C -> option C *)
  (* ; halted : C -> val *)
  (* ; corestep : G -> C -> M -> C -> M -> Prop *)
  (* (* plus lemmas *) *)
  (* }. *)
  
  (* Parameter csem: semantics. *)
  (* Parameter pstate : Type. *)
  (* Parameter penv : Type. *)
  (* Parameter turn_state : pstate -> Component.id. *)
  (* Parameter psi: interface. *)
  (* Parameter partialize: interface -> (state csem) -> pstate. *)
  (* Parameter lift: interface -> pstate -> (state csem). *)
  (* (* TODO lemma between lift and partialize *) *)
  (* Parameter lift_env: penv -> (genvtype csem). *)
  (* (* Parameter stack_push: pstate -> Component.id -> pstate. *) *)
  (* Parameter is_program_component : penv -> Component.id -> Prop. *)
  (* Parameter is_context_component : penv -> Component.id -> Prop. *)

  (* Definition initial_state (ps:pstate) := initial_state csem (lift psi ps). *)
  (* Definition final_state (ps:pstate) := final_state csem (lift psi ps). *)
  (* Inductive pstep: penv -> pstate -> trace -> pstate -> Prop := *)
  (* (* TODO the event can't be read *) *)
  (* | program_all: forall g ps ps', *)
  (*     is_program_component g (turn_state ps) -> *)
  (*     (step csem) (lift_env g) (lift psi ps) E0 (lift psi ps') -> *)
  (*     pstep g ps E0 ps' *)
  (* | context_epsilon: forall g ps, *)
  (*     is_context_component g (turn_state ps) -> *)
  (*     Program.has_component_id psi (turn_state ps) -> *)
  (*     pstep g ps E0 ps *)
  (* | Context_Internal_Call: *)
  (*     forall pgps pgps' mem C C' P call_arg, *)
  (*       let C = turn_state(ps) in *)
  (*       let C' = turn_state(ps') in *)
  (*       C' <> C -> *)
  (*       imported_procedure (genv_interface G) C C' P -> *)
  (*       is_context_component G C -> *)
  (*       is_context_component G C' -> *)
  (*       pgps' = (C, None) :: pgps -> *)
  (*       let t := [ECall C P call_arg C'] in *)
  (*       step G (CC (pgps,mem,C)) t (CC (pgps',mem,C')). *)

  (*     step G (PC (pgps,mem,regs,pc)) E0 (PC (pgps,mem',regs',pc')) *)
             
  (* Definition psem (psi:interface) (p:program) := *)
  (*   Semantics_gen (step csem) (initial_state csem) (final_state csem) (globalenv csem). *)


End Lang.

(* Every language is a subtype of Lang and implements its signature *)
(* Note: most things are just axioms *)

(* Intermediate *)
Module I <: Lang.
  Axiom state: Type.
  Axiom initial_state: state -> Prop.
  Definition program := Intermediate.program.
  Definition get_interface := Intermediate.prog_interface.
  Axiom valid: program -> Prop.

  Definition complete (p:program) :=
    valid p /\ icomplete (get_interface p).
  Definition complete2 (p1 p2:program) :=
    valid p1 /\ valid p2 /\
    icomplete2 (get_interface p1) (get_interface p2).

  Axiom main_c : Component.id.
  Axiom main_p : Procedure.id.
  Definition sem p := CS.sem p main_c main_p. 
  Definition psem (psi:interface) p := PS.sem p main_c main_p.

  (* linking of two partial programs, this is restricted to the
     complete case, we could generalize by asking that p1 and p2 are
     compatible *)
  Axiom link: program -> program -> program.
  Axiom link_spec:
    forall (p1 p2 p:program),
      complete2 p1 p2 ->
      NMap.Equal (NMapExtra.update (get_interface p1) (get_interface p2)) (get_interface p) /\
      complete (link p1 p2).

  Axiom decomposition:
    forall beh (c p:program),
      complete2 c p ->
      program_behaves (sem (link c p)) beh ->
      program_behaves (psem (get_interface c) p) beh.

  (* CH: TODO: I find the `valid` and `icomplete2` **preconditions** disturbing;
               this makes invalid or incomplete programs fully_defined *)
End I.

(* Source *)
Module S <: Lang.
  Axiom state: Type.
  Axiom initial_state: state -> Prop.
  Axiom program : Type.
  Axiom valid: program -> Prop.
  Axiom get_interface: program -> interface.
  Definition complete (p:program) :=
    valid p /\ icomplete (get_interface p).
  Definition complete2 (p1 p2:program) :=
    valid p1 /\ valid p2 /\
    icomplete2 (get_interface p1) (get_interface p2).
  Axiom sem: program -> semantics.
  Axiom psem: interface -> program -> semantics.
  
  Axiom link: program -> program -> program.

  Axiom definability:
    forall (beh:program_behavior) (psi:interface) (p:program),
      valid p ->
      icomplete2 psi (get_interface p) ->
      program_behaves (psem psi p) beh ->
      exists (c:program),
        valid c /\
        get_interface c = psi /\
        program_behaves (sem (link c p)) beh.
End S.


(* Source to Intermediate *)
Module SI.
  (* TODO
     compcert defined the compiler as:
     - a function transf_c_program (p: Csyntax.program) : res Asm.program
     - a relation match_prog: Csyntax.program -> Asm.program -> Prop
     and proves their equivalence in transf_c_program_match.
 *)
  (* compiles partial programs *)
  Axiom compile : S.program -> I.program.
  Axiom compile_spec:
    forall (p:S.program),
      S.valid p ->
      I.valid (compile p) /\
      NMap.Equal (S.get_interface p) (I.get_interface (compile p)).

  Axiom Sreceptive:
    forall P, receptive (S.sem P).
  Axiom Ideterminate:
    forall p, determinate (I.sem p).
  
  Axiom complete_forward_simulation :
    forall P,
      S.complete P ->
      forward_simulation (S.sem P) (I.sem (compile P)).

  Definition complete_backward_simulation:
    forall P,
      S.complete P ->
      backward_simulation (S.sem P) (I.sem (compile P)).
  Proof.
    intros. apply forward_to_backward_simulation.
    apply complete_forward_simulation.
    auto. auto.
    apply Sreceptive. apply Ideterminate.
  Qed.
  
  Theorem complete_compiler_correctness:
    forall P behi,
      S.complete P ->
      program_behaves (I.sem (compile P)) behi ->
      exists behs, program_behaves (S.sem P) behs /\ behavior_improves behs behi.
  Proof.
    intros. eapply backward_simulation_behavior_improves; eauto.
    apply complete_backward_simulation; auto.
  Qed.


  Variable partial_match_states: state  -> state L2 -> Prop.
  
  Hypothesis partial_match_initial_states:
    forall s1, initial_state L1 s1 ->
               exists s2, initial_state L2 s2 /\ match_states s1 s2.
  
  Hypothesis partial_match_final_states:
    forall s1 s2 r,
      match_states s1 s2 ->
      final_state L1 s1 r ->
      final_state L2 s2 r.


  (* TODO this should be provable from backward_simulation_complete *)
  (* TODO this should backward *)
  Definition partial_forward_simulation:
    forall P psi,
      S.valid P ->
      icomplete2 psi (S.get_interface P) ->
      forward_simulation (S.psem psi P) (I.psem psi (compile P)).
  Proof.
    intros P psi ValP icomp.
    eapply forward_simulation_plus.



  Axiom backward_simulation_behavior_improves_p:
    forall psi p1 p2,
      backward_simulation (S.psem psi p1) (I.psem psi p2) ->
    forall beh2, program_behaves (I.psem psi p2) beh2 ->
    exists beh1, program_behaves (S.psem psi p1) beh1 /\ behavior_improves_p beh1 beh2 (S.get_interface p1).

  Theorem partial_compiler_correctness:
    forall P psi behi,
      S.valid P ->
      icomplete2 psi (S.get_interface P) ->
      program_behaves (I.psem psi (compile P)) behi ->
      exists behs, program_behaves (S.psem psi P) behs /\ behavior_improves_p behs behi (S.get_interface P).
  Proof.
    intros. eapply backward_simulation_behavior_improves_p; eauto.
    apply partial_backward_simulation; auto.
  Qed.

End SI.



(* Micro-policies target language *)
Module MP <: Lang.
  Axiom program : Type.
  Axiom valid: program -> Prop.
  Axiom get_interface: program -> interface.
  Definition complete (p:program) := valid p /\ icomplete (get_interface p).
  Definition complete2 (p1 p2:program) := valid p1 /\ valid p2 /\ icomplete2 (get_interface p1) (get_interface p2).
  Axiom sem: program -> semantics.
  Axiom psem: interface -> program -> semantics.
End MP.

(* Software Fault Isolation target language *)
Module SFI <: Lang.
  Axiom program : Type.
  Axiom valid: program -> Prop.
  Axiom get_interface: program -> interface.
  Definition complete (p:program) := valid p /\ icomplete (get_interface p).
  Definition complete2 (p1 p2:program) := valid p1 /\ valid p2 /\ icomplete2 (get_interface p1) (get_interface p2).
  Axiom sem: program -> semantics.
  Axiom psem: interface -> program -> semantics.
End SFI.


(* Interface expected for a compiler from Intermediate to Target
   Both backend MP and SFI need to implement this interface *)
Module Type IT.
  Declare Module T : Lang.
  
  (* TODO
     compcert defines the compiler as:
     - a function transf_c_program (p: Csyntax.program) : res Asm.program
     - a relation match_prog: Csyntax.program -> Asm.program -> Prop
     and proves their equivalence in transf_c_program_match.
   *)
  (* Note that 
     - this compiler only works on complete programs as
       opposed to SI.compile that works on partial programs 
     - undefined programs, such as a context linked with a FD program,
       will have a defined behavior once compiled.
       TODO do we provide any guarantee in that case?
   *)
  Parameter compile : I.program -> T.program.
  Parameter compile_spec:
    forall (p:I.program),
      I.complete p -> T.valid (compile p) /\
                      I.get_interface p = T.get_interface (compile p).
  
  (* 
     The following properties are special because they depend on
     compiling the complete intermediate program.
     Note:
     - the compiled program doesn't have any UB so we don't need to
       preserve it.
   *)
  Parameter special_decomposition :
    forall beh (c p:I.program),
      I.complete2 c p ->
      let ip := compile (I.link c p) in
      program_behaves (T.sem ip) beh ->
      program_behaves (T.psem (I.get_interface c) ip) beh.

  Parameter special_compiler_correctness:
    forall (behi beht:program_behavior) (c p:I.program),
      I.complete2 c p ->
      let ip := I.link c p in
      program_behaves (T.psem (I.get_interface c) (compile ip)) beht ->
      program_behaves (I.psem (I.get_interface c) p) behi /\
      behavior_improves_p behi beht (I.get_interface p).

  (* At target level all behaviors are defined, if the program is
     ill-formed the behavior is termination *)
  Parameter sem_spec:
    forall p b, program_behaves (T.sem p) b -> not_wrong b.
End IT.

(* (* Micro-policies compiler *) *)
(* Module MPC <: IT. *)
(*   Module T := MP. *)
  
(*   Axiom compile : I.program -> T.program. *)
(*   Axiom compile_spec: *)
(*     forall (p:I.program), *)
(*       I.complete p -> T.valid (compile p) /\ *)
(*                    I.get_interface p = T.get_interface (compile p). *)

(*   (* this would be used in the definition of T.psem and in match_states *) *)
(*   (* Axiom partialize: interface -> T.program -> T.program. *) *)
(*   (* Axiom partialize_spec: *) *)
(*   (*   forall psi (p:T.program), *) *)
(*   (*     T.valid p -> *) *)
(*   (*     contained psi (T.get_interface p) -> *) *)
(*   (*     (T.get_interface p) = (T.get_interface (partialize psi p))++psi. *) *)

(*   Axiom sem_spec: *)
(*     forall p b, program_behaves (T.sem p) b -> not_wrong b. *)

(*   Axiom psem_spec: *)
(*     forall psi p b, program_behaves (T.psem psi p) b -> not_wrong b. *)

(*   (* assuming we have a simulation *) *)
(*   Axiom decomposition_simulation: *)
(*     forall psi tp, *)
(*     forward_simulation (T.sem tp) (T.psem psi tp). *)
    
(*   Definition decomposition: *)
(*     forall beh psi (p:T.program), *)
(*       T.valid p -> *)
(*       contained psi (T.get_interface p) -> *)
(*       program_behaves (T.sem p) beh -> *)
(*       program_behaves (T.psem psi p) beh. *)
(*   Proof. *)
(*     intros b psi p Hvalp Hcont Hsem. *)
(*     eapply forward_simulation_same_safe_behavior. *)
(*     apply decomposition_simulation. *)
(*     assumption. *)
(*     apply (sem_spec p). *)
(*     assumption. *)
(*   Qed. *)
  
(*   (* we can prove special decomposition using the more general *)
(*      decomposition *) *)
(*   Definition special_decomposition : *)
(*     forall beh (c p:I.program), *)
(*       I.complete2 c p -> *)
(*       program_behaves (T.sem (compile (I.link c p))) beh -> *)
(*       program_behaves (T.psem (I.get_interface c) (compile (I.link c p))) beh. *)
(*   Proof. *)
(*     intros b c p Hcomp H. *)
(*     destruct (I.link_spec c p (I.link c p) Hcomp) as [Hif [Hvalip Hcompip]]. *)
(*     destruct (compile_spec (I.link c p)) as [HvalPcom Hcompint]. *)
(*     unfold I.complete. *)
(*     split; auto. *)
(*     apply decomposition. *)
(*     assumption. *)
(*     rewrite <- Hcompint. *)
(*     unfold contained. *)
(*     exists (I.get_interface p). *)
(*     auto. *)
(*     auto. *)
(*   Qed. *)

(*   (* Note: despite the name this is backward simulation. *)
(*      In compcert there are two simulation: *)
(*      - forward: is just a simulation, it is forward or backward depending on the order of the arguments *)
(*      - backward: add the condition that the first argument must be a safe program *)
(*   *) *)
(*   Axiom special_compiler_correctness_simulation: *)
(*     forall (c p:I.program), *)
(*       I.complete2 c p -> *)
(*       I.fully_defined (I.get_interface c) p -> *)
(*       let ip := I.link c p in *)
(*       forward_simulation (T.psem (I.get_interface c) (compile ip)) (I.psem (I.get_interface c) p). *)

(*   Definition special_compiler_correctness: *)
(*     forall beh (c p:I.program), *)
(*       I.complete2 c p -> *)
(*       I.fully_defined (I.get_interface c) p -> *)
(*       let ip := I.link c p in *)
(*       program_behaves (T.psem (I.get_interface c) (compile ip)) beh -> *)
(*       program_behaves (I.psem (I.get_interface c) p) beh. *)
(*   Proof. *)
(*     intros b c p Hcompl pFD ip Hcomp. *)
(*     apply forward_simulation_same_safe_behavior with (L1:=(T.psem (I.get_interface c) (compile ip))). *)
(*     apply special_compiler_correctness_simulation. *)
(*     assumption. *)
(*     assumption. *)
(*     assumption. *)
(*     apply (psem_spec (I.get_interface c) (compile ip)). *)
(*     assumption. *)
(*   Qed. *)
(* End MPC. *)

(* (* Software Fault Isolation compiler *) *)
(* Module SFIC <: IT. *)
(*   Module T := SFI. *)
  
(*   Axiom compile : I.program -> T.program. *)
(*   Axiom compile_spec: *)
(*     forall (p:I.program), *)
(*       I.complete p -> T.valid (compile p) /\ *)
(*                    I.get_interface p = T.get_interface (compile p). *)

(*   (* Axiom partialize: interface -> T.program -> T.program. *) *)
(*   (* Axiom partialize_spec: *) *)
(*   (*   forall psi (p:T.program), *) *)
(*   (*     T.valid p -> *) *)
(*   (*     contained psi (T.get_interface p) -> *) *)
(*   (*     (T.get_interface p) = (T.get_interface (partialize psi p))++psi. *) *)

(*   Axiom sem_spec: *)
(*     forall p b, program_behaves (T.sem p) b -> not_wrong b. *)

(*   Axiom decomposition_simulation: *)
(*     forall psi c p, *)
(*       I.complete2 c p -> *)
(*       I.fully_defined (I.get_interface c) p -> (* CH: do we really need this? *) *)
(*       let ip := compile (I.link c p) in *)
(*       forward_simulation (T.sem ip) (T.psem psi ip). *)

(*   (* there is no generic decomposition, we need to prove *)
(*       special_decomposition *) *)
(*   Definition special_decomposition : *)
(*     forall beh (c p:I.program), *)
(*       I.complete2 c p -> *)
(*       I.fully_defined (I.get_interface c) p -> (* CH: do we really need this? *) *)
(*       let ip := compile (I.link c p) in *)
(*       program_behaves (T.sem ip) beh -> *)
(*       program_behaves (T.psem (I.get_interface c) ip) beh. *)
(*   Proof. *)
(*     intros b c p Hcompl pFD ip Hsem. *)
(*     apply (decomposition_simulation (I.get_interface c) c p Hcompl) in pFD. *)
(*     apply (forward_simulation_same_safe_behavior pFD). *)
(*     assumption. *)
(*     apply (sem_spec ip). *)
(*     assumption. *)
(*   Qed. *)
    
(*   Axiom special_compiler_correctness: *)
(*     forall beh (c p:I.program), *)
(*       I.complete2 c p -> *)
(*       I.fully_defined (I.get_interface c) p -> *)
(*       let ip := I.link c p in *)
(*       program_behaves (T.psem (I.get_interface c) (compile ip)) beh -> *)
(*       program_behaves (I.psem (I.get_interface c) p)  beh. *)
(* End SFIC. *)




(* The proof is modular wrt the backend *)
Module Main (IT : IT).
  (* 
   This property is different from the one we started from: there is
   no concept of linking at the low level.
   A program is composed at the intermediate, compiled as a complete
   program and run at the target.
   Instead of linking to partial target programs, we go to the partial
   semantics by partializing a complete target program.
   *)

  Definition robust_compilation_dynamic_compromise:
    forall (c:I.program) (P:S.program) (beht:program_behavior),
      I.valid c ->
      S.valid P ->
      icomplete2 (I.get_interface c) (S.get_interface P) ->
      program_behaves (IT.T.sem (IT.compile (I.link c (SI.compile P)))) beht ->
      exists C behs,
        S.valid C /\
        S.get_interface C = I.get_interface c /\
        program_behaves (S.sem (S.link C P)) behs /\
        behavior_improves_p behs beht (S.get_interface P).
  Proof.
    intros c P bt Hvalc HvalP Hicompl Hsem.
    destruct (SI.compile_spec P HvalP) as [Hvalcomp Hif] .
    apply IT.special_decomposition in Hsem.
    eapply IT.special_compiler_correctness in Hsem as [H1 H2].
    apply SI.compiler_correctness in H1.
    apply S.definability in H1.
    destruct H1 as [C [H3a [H3b H3c]]].
    exists C. exists bt.
    repeat split; eauto.
    rewrite Hif.
    auto.
    auto.
    auto.
    auto.
    auto.
    unfold I.complete2. rewrite <- Hif. repeat split; auto.
    unfold I.complete2. rewrite <- Hif. repeat split; auto.
  Qed.

(* (* This property is strictly weaker than the above, but has the *)
 (*    advantage of not mentioning the intermediate language *) *)
  (* Definition robust_compilation_static_compromise_weaker := *)
  (*   forall (Q P:S.program) (beh:program_behavior), *)
  (*     S.complete2 Q P -> *)
  (*     S.fully_defined (S.get_interface Q) P -> *)
  (*     program_behaves (IT.T.sem (IT.compile (I.link (SI.compile Q) (SI.compile P)))) beh -> *)
  (*     exists C, *)
  (*       S.valid C /\ *)
  (*       S.get_interface C = S.get_interface Q /\ *)
  (*       S.fully_defined (S.get_interface P) C /\  *)
  (*       program_behaves (S.sem (S.link C P)) beh. *)

  (* Corollary robust_compilation_corrolary : *)
  (*   robust_compilation_static_compromise -> *)
  (*   robust_compilation_static_compromise_weaker. *)
  (* Proof. *)
  (*   intros RC Q P b Hcompl SFD H2. *)
  (*   specialize (RC (SI.compile Q) P b). *)
  (*   assert (SFD2 := SFD). *)
  (*   assert (Hcompl2 := Hcompl). *)
  (*   destruct Hcompl2 as [HvalQ [HvalP Hicompl]]. *)
  (*   destruct (SI.compile_spec Q). *)
  (*   auto. *)
  (*   rewrite <- H0 in RC. *)
  (*   apply (RC H HvalP Hicompl SFD H2). *)
  (* Qed. *)
End Main.