Require Import Common.Definitions.
Require Import Common.Util.

From mathcomp Require Import ssreflect ssrfun ssrbool.

(* an imported procedure is either open (the interface is missing)
   or exported by the right component *)
Definition sound_interface (interface : Program.interface) : Prop :=
  forall C C' P, imported_procedure interface C C' P ->
  forall CI',
    Program.has_component interface C' CI' ->
    Component.is_exporting CI' P.

Definition linkable (i1 i2 : Program.interface) : Prop :=
  sound_interface (unionm i1 i2) /\ fdisjoint (domm i1) (domm i2).

Theorem linkable_sym:
  forall {i1 i2},
    linkable i1 i2 -> linkable i2 i1.
Proof.
  intros i1 i2 Hlinkable.
  inversion Hlinkable; subst.
  constructor;
    try assumption.
  - rewrite unionmC; auto.
    unfold fdisjoint. rewrite fsetIC. auto.
  - unfold fdisjoint. rewrite fsetIC. auto.
Qed.

Theorem linkable_emptym:
  forall i,
    sound_interface i ->
    linkable i emptym.
Proof.
  intros i Hsound. constructor.
  - now rewrite unionm0.
  - rewrite domm0. apply fdisjoints0.
Qed.

(* an imported procedure is always exported by the right component *)
Definition closed_interface (interface : Program.interface) : Prop :=
  forall C C' P, imported_procedure interface C C' P ->
                 exported_procedure interface C' P.

Lemma closed_interface_is_sound:
  forall iface,
    closed_interface iface -> sound_interface iface.
Proof.
  unfold closed_interface, sound_interface.
  intros iface Hiface_closed C C' P Himported CI' HCI'.
  specialize (Hiface_closed C C' P Himported).
  destruct Hiface_closed as [CI'' [HCI'' Hexporting]].
  unfold Program.has_component in HCI', HCI''.
  enough (HsameCI: CI' = CI'').
  - subst. auto.
  - rewrite HCI'' in HCI'. inversion HCI'. reflexivity.
Qed.
