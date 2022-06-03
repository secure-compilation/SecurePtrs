# SecurePtrs #

This branch contains the Coq development of the paper:
- **[SecurePtrs: Proving Secure Compilation Using
     Data-Flow Back-Translation nd Turn-Taking Simulation](https://arxiv.org/abs/2110.01439)**.
   Akram El-Korashy, Roberto Blanco, Jérémy Thibault,
   Adrien Durier, Deepak Garg, and Catalin Hritcu.
   arXiv:2110.01439. October 2021.

## Installation ##

### Prerequisites ###

This development has been built with the following combinations of Coq releases
and versioned libraries:

Coq 8.12.2
- Mathematical Components 1.11.0
- Extensional Structures 0.2.2
- Equations 1.2.4

Coq 8.13.2
- Mathematical Components 1.13.0
- Extensional Structures 0.3.1
- Equations 1.3

Coq 8.14.1
- Mathematical Components 1.13.0
- Extensional Structures 0.3.1
- Equations 1.3

Dependencies can be installed through the OCaml package manager, OPAM.

- Coq (package `coq`) is available through the official
  [Ocaml OPAM repository](http://opam.ocaml.org/).
- Stable releases of Mathematical Components (packages `coq-mathcomp-ssreflect`,
  `coq-mathcomp-fingroup` and `coq-mathcomp-algebra`), Extensional Structures
  (package `coq-extructures`), and Equations (package `coq-equations`)
  are available through the [Coq OPAM repository](https://coq.inria.fr/opam/released/).

### Build ###

Run `make` at the root to build the development.

## Definitions and theorems ##

The following list maps the definitions and statements in the paper to their
mechanized counterparts in Coq.

- Definition 2.1 (RSP~): see statement of Theorem `RSC` in `RSC.v` for an instance of this definition

- Assumption 2.3 (FCC): `S2I/Compiler.v`, Axiom `forward_simulation_star`

- Lemma 2.4 (recomposition): `Intermediate/RecompositionRel.v`, Theorem `recombination_trace_rel`

- Assumption 2.5 (BCC): `S2I/Compiler.v`, Axiom `backward_simulation_star`

- Definition 2.6 (interaction-trace events): `CompCert/Events.v`, Inductive type `event`

- Definition 3.2 (data-flow events) `Common/TracesInform.v`, Inductive type `event_inform`

- Lemma 3.4 (enrichment): `Intermediate/CS.v`, Lemma `star_sem_non_inform_star_sem_inform`

- Lemma 3.5 (data-flow back-translation): `Source/Definability.v`, Lemma `definability`

- Definition 3.9 (turn-taking memory relation): `Intermediate/RecompositionRelCommon.v`, Inductive proposition `mergeable_internal_states`

- Definition 3.10 (relation on interaction traces): `Common/RenamingOption.v`, Inductive proposition `traces_shift_each_other_option`

- Rule `Jump` (Section 4): `Intermediate/CS.v`, case `Jump` of inductive `step`

- Rule `Store` (Section 4): `Intermediate/CS.v`, case `Store` of inductive `step`

- Theorem 4.1 (RSP~): Theorem `RSC` in `RSC.v`

- Lemma 5.1 (trace prefix mimicking): `Source/Definability.v`, Lemma `definability_gen_rel_right`

- Definition 5.2 (memory relation at interaction events): `Intermediate/RecompositionRelCommon.v`, Inductive proposition `mergeable_border_states`

- Lemma 5.3 (strengthening at interaction events): `Intermediate/RecompositionRelStrengthening.v`, Theorem `threeway_multisem_event_lockstep_program_step`

- Lemma 5.4 (option simulation): `Intermediate/RecompositionRelOptionSim.v`, Lemma `merge_states_silent_star`

- Lemma 5.5 (lockstep simulation): `Intermediate/RecompositionRelLockstepSim.v`, Theorem `threeway_multisem_star_E0`

- Lemma 5.6 (symmetry of the turn-taking state simulation relation): `Intermediate/RecompositionRelCommon.v`, Lemma `mergeable_internal_states_sym`

## Axioms ##

### How to find axioms/admits ###

All our results are admit-free and only rely, at most, on some of the axioms
specified below. Any other axioms or admitted theorems found in the development
are not used in our proofs.

To verify this, use the Coq command `Print Assumptions` to examine the axioms
that apply to the theorems of interest. An index of the above definitions and
theorems is given at the end of the top-level file `RSC.v`.

### Axioms about correct compilation of whole programs ###

We leave some standard statements about the *correct* compilation of whole
programs as axioms because they are not really the focus of 
our novel *secure* compilation proof techniques.

Proving these kind of correctness results is typically laborious and we do not
expect the proof to be particularly insightful for our chosen pair of languages.

In fact, one of the key goals of the proof technique for the main secure
compilation theorem is to demonstrate that standard results about correct
compilation can be reused by (rather than implicitly reproved as part of) the
secure compilation proof, since proving these theorems is typically a big manual
effort that one would wish to avoid duplicating.

#### Compilation and well-formedness ####
We assume that every well-formed source program can be successfully compiled
(`well_formed_compilable`),
and that compiling preserves certain well-formedness conditions 
(`Compiler.compilation_preserves_well_formedness`,
` compilation_preserves_main`, `compilation_has_matching_mains`).
```coq
Compiler.well_formed_compilable
  : forall (p : Source.program) (psz : {fmap Component.id -> nat}),
    Source.well_formed_program p ->
    exists pc : Intermediate.program, compile_program p psz = Some pc

Compiler.compilation_preserves_well_formedness
  : forall (p : Source.program) (psz : {fmap Component.id -> nat})
      (p_compiled : Intermediate.program),
    Source.well_formed_program p ->
    compile_program p psz = Some p_compiled ->
    Intermediate.well_formed_program p_compiled

compilation_preserves_main
  : forall (p : Source.program) (pstksize : {fmap Component.id -> nat})
      (p_compiled : Intermediate.program),
    Source.well_formed_program p ->
    compile_program p pstksize = Some p_compiled ->
    (exists main : expr, Source.prog_main p = Some main) <->
    Intermediate.prog_main p_compiled

compilation_has_matching_mains
  : forall (p : Source.program) (psz : {fmap Component.id -> nat})
      (p_compiled : Intermediate.program),
    Source.well_formed_program p ->
    compile_program p psz = Some p_compiled -> matching_mains p p_compiled
```

#### Separate compilation ####
We assume that the compiler satisfies `separate_compilation`:
compilation and linking commute.
```coq
separate_compilation
  : forall (p : Source.program) (psz : {fmap Component.id -> nat})
      (c : Source.program) (csz : {fmap Component.id -> nat})
      (p_comp c_comp : Intermediate.program),
    Source.well_formed_program p ->
    Source.well_formed_program c ->
    linkable (Source.prog_interface p) (Source.prog_interface c) ->
    compile_program p psz = Some p_comp ->
    compile_program c csz = Some c_comp ->
    compile_program (Source.program_link p c) (unionm psz csz) =
    Some (Intermediate.program_link p_comp c_comp)
```

#### Compiler correctness ####
We also assume CompCert-style compiler correctness, in the form of a
forward simulation `forward_simulation_star`
and a backward simulation `backward_simulation_star`:
```coq
Compiler.forward_simulation_star
  : forall (p : Source.program) (t : Events.trace Events.event)
      (s : state (S.CS.sem p)) (metasize : Component.id -> nat),
    Source.closed_program p ->
    Source.well_formed_program p ->
    disciplined_program p ->
    NoLeak.good_Elocal_usage_program p ->
    Star (S.CS.sem p) (S.CS.initial_machine_state p) t s ->
    exists
      (s' : I.CS.state) (t' : Events.trace Events.event) 
    (psz : {fmap nat_ordType -> nat}) (p_compiled : Intermediate.program),
      domm (T:=nat_ordType) (S:=nat) psz =
      domm (T:=nat_ordType) (S:=Component.interface)
        (Source.prog_interface p) /\
      compile_program p psz = Some p_compiled /\
      Star (I.CS.sem_non_inform p_compiled)
        (I.CS.initial_machine_state p_compiled) t' s' /\
      traces_shift_each_other_option metasize metasize t t'

Compiler.backward_simulation_star
  : forall (p : Source.program) (psz : {fmap Component.id -> nat})
      (p_compiled : Intermediate.program) (t : Events.trace Events.event)
      (s : state (I.CS.sem_non_inform p_compiled))
      (metasize : Component.id -> nat),
    Source.closed_program p ->
    Source.well_formed_program p ->
    disciplined_program p ->
    NoLeak.good_Elocal_usage_program p ->
    compile_program p psz = Some p_compiled ->
    Star (I.CS.sem_non_inform p_compiled)
      (I.CS.initial_machine_state p_compiled) t s ->
    exists (s' : state (S.CS.sem p)) (t' : Events.trace Events.event),
      Star (S.CS.sem p) (S.CS.initial_machine_state p) t' s' /\
      traces_shift_each_other_option metasize metasize t t'
```

#### Compiler preserves the privacy of the local buffer ####
Finally, we assume `Compiler.compiler_preserves_non_leakage_of_private_pointers`,
which states that our compiler preserves the privacy of the local buffer.
Such a result can likely be proved by using the fine-grained simulation invariants
in an actual compiler correctness proof.
```coq
Compiler.compiler_preserves_non_leakage_of_private_pointers
  : forall (p : Source.program) (psz : {fmap Component.id -> nat})
      (p_compiled : Intermediate.program)
      (metadata_size : Component.id -> nat),
    Source.closed_program p ->
    Source.well_formed_program p ->
    compile_program p psz = Some p_compiled ->
    S.CS.private_pointers_never_leak_S p metadata_size ->
    private_pointers_never_leak_I p_compiled metadata_size
```

### Logical axioms ###

The following standard axioms are used occasionally in our proofs.

```coq
ProofIrrelevance.proof_irrelevance : forall (P : Prop) (p1 p2 : P), p1 = p2

FunctionalExtensionality.functional_extensionality_dep
  : forall (A : Type) (B : A -> Type) (f g : forall x : A, B x),
    (forall x : A, f x = g x) -> f = g

Classical_Prop.classic : forall P : Prop, P \/ ~ P
```

## Index of definitions ##

The source language `SafeP` corresponds to `Source` in the code. The target language `Mach` corresponds to `Intermediate` in the code.

- Backtranslation function `↑`: function `procedures_of_trace` in `Source/Definability.v`
- Data-flow events `E`: inductive `event_inform` in `Common/TracesInform.v`
- Memory projection `proj_P(Mem)`: implicit in definitions `mem_of_part_executing_rel_original_and_recombined` and `mem_of_part_not_executing_rel_original_and_recombined_at_internal` in `Intermediate/RecompositionRelCommon.v`
- Value renaming `valren`: function `rename_value_template_option` in `Common/RenamingOption.v`
- The +1 block id renaming: Implemented by instantiating `shift_value_option` with `uniform_shift 0` and `uniform_shift 1`, in `Common/RenamingOption.v`
- Turn-taking simulation invariant `state_rel_tt`: definition `mergeable_internal_states` in `Intermediate/RecompositionRelCommon.v`
- Turn-taking simulation relation `mem_rel_tt`: memory part of the `mergeable_internal_states` definition in `Intermediate/RecompositionRelCommon.v`
- Strong memory relation holding at all locations of the executing part `mem_rel_exec`: definition `mem_of_part_executing_rel_original_and_recombined` in `Intermediate/RecompositionRelCommon.v`
- Memory relation holding only at private locations of the non-executing part `mem_rel_not_exec`: definition `mem_of_part_not_executing_rel_original_and_recombined_at_internal` in `Intermediate/RecompositionRelCommon.v`
- Function `shared`: inductive `addr_shared_so_far` in `Common/RenamingOption.v`
- Function `private`: negation of the inductive `addr_shared_so_far` in `Common/RenamingOption.v`
- Linking `C ∪ P`: functions `program_link` in `Source/Language.v` and `Intermediate/Machine.v`
- Trace relation `~`: definition `traces_shift_each_other_option` in `Common/RenamingOption.v`
- Compilation function `↓`: function `compile_program` in `S2I/Compiler.v`
- Step relation `⇝`: definitions `kstep` in `Source/CS.v`; `step_non_inform` for non-data-flow semantics and `step` for data-flow semantics in `Intermediate/CS.v`
- Reflexive transitive closure `^*`: inductive `star` in `CompCert/Smallstep.v`
- Interaction (non-data-flow) events `e`: definition `event` in `CompCert/Events.v`
- Memory `Mem` or `mem`: Module `Memory` in `Common/Memory.v`
- Component memory `cMem`: Module `ComponentMemory` in `Common/Memory.v`
- Source (SafeP) expressions `exp`: definition `expr` in `Source/Language.v`
- Target (Mach) instructions `instr`: definition `instr` in `Intermediate/Machine.v`
- Values `v`: definition `value` in `Common/Values.v`
- Removal of all internal data-flow events `remove_df`: function `project_non_inform` in `Common/TracesInform.v`
- Back-translation `mimicking_state` invariant: definition `well_formed_state` in `Source/Definability.v`
- Back-translation of a data-flow event: definition `expr_of_event` in `Source/Definability.v`
- Trace concatenation `++`: function `Eapp` in `CompCert/Events.v`
- Border-state relation `state_rel_border`: definition `mergeable_border_states` in `Intermediate/RecompositionRelCommon.v`
- "Is executing in" relation: `is_program_component` and `is_context_component` in `Intermediate/CS.v`

## License ##
- This code is licensed under the Apache License, Version 2.0 (see `LICENSE`)
- The code in the `CompCert` dir is adapted based on files in the
  `common` and `lib` dirs of CompCert and is thus dual-licensed under
  the INRIA Non-Commercial License Agreement and the GNU General
  Public License version 2 or later (see `CompCert/LICENSE`)
