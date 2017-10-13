Require Import Coq.ZArith.ZArith.
Require Import Coq.Structures.Equalities.
Require Import Coq.Lists.List.

Require Import Common.Definitions.
Require Import Common.Util.
Require Import Common.Maps.
Require Import SFIUtil.

Require Import QuickChick.QuickChick.
Import QcDefaultNotation. Import QcNotation. Open Scope qc_scope.

From mathcomp.ssreflect Require Import ssreflect ssrbool eqtype.

(******************************************
 * Basic Risc Machine Definition
 *******************************************)
Module RiscMachine.

  Definition value := Z.

  Definition immediate := Z.

  Definition address := N.


  Module Register.
    
    Open Scope N_scope.
    Definition t := N.
    Definition R_ONE: t := 1.
    Definition R_COM : t := 2.
    Definition R_AUX1 : t := 3.
    Definition R_AUX2 : t := 4.
    Definition R_RA : t := 5.
    Definition R_SP : t := 6. 
    (* reserved SFI registers *)
    Definition R_SFI_SP: t := 26.
    Definition R_AND_CODE_MASK : t := 27.
    Definition R_AND_DATA_MASK : t := 28.
    Definition R_OR_CODE_MASK : t := 29.
    Definition R_OR_DATA_MASK : t := 30.
    Definition R_T : t := 31.
    Definition R_D : t := 32.
    Close Scope N_scope.
    
    Definition NO_REGISTERS : nat := 33.
    
    (* Definition IS_NOT_SFI_REGISTER (reg:N) := reg < 26. *)
    (* Definition IS_SFI_REGISTER (reg:N) := reg > 25. *)
    (* Definition is_not_sfi_reg_bool (reg:N) := reg <? 26.     *)
    (* Definition  IS_SFI_SP_REGISTER (reg:N) := reg = 26.     *)
    (* Definition is_sfi_sp_register_bool (reg:N) := reg =? 26. *)

    Definition eqb_reg (r1 r2 : t) : bool :=
      N.eqb r1 r2.

  End Register.

  Definition pc : Set := address.

  Definition PC0 : pc := N0.
  
  Module RegisterFile <: UsualDecidableType.
    
    Definition t : Set := list value.

    Fixpoint is_zero (gen_regs:t)  : Prop :=
      match gen_regs with
      | [] => True
      | r :: l' => (r = Z0 )/\ is_zero l'
      end.

    Definition reset_all : t := repeat Z0 Register.NO_REGISTERS.

    Definition set_register (reg : Register.t) (val : value)
               (gen_regs  : t) : t :=
      Util.Lists.update gen_regs (N.to_nat reg) val.

    Definition get_register (reg : Register.t) (gen_regs : t) : option value :=
      ListUtil.get (N.to_nat reg) gen_regs.

    Fixpoint eqb (regs1 regs2 : t) : bool :=
      match (regs1,regs2) with
      | ([],[]) => true
      | (v1::regs1',v2::regs2') => (Z.eqb v1 v2) && (eqb regs1' regs2')
      | _ => false
      end.

  
    Lemma eqb_eq: forall (regs1 regs2 : t),
        (eqb regs1 regs2) = true <-> regs1 = regs2.
    Proof.
      split.
      - intro H. generalize dependent regs2. induction regs1.
        + intros. destruct regs2.
          * reflexivity.
          * inversion H.
        + intros. destruct regs2.
          * inversion H.
          * inversion H. apply andb_true_iff in H1.
            destruct H1 as [Hh Ht].
            apply IHregs1 in Ht.
            rewrite Ht.
            rewrite Z.eqb_eq in Hh. 
            
    Theorem eq_dec: forall regs1 regs2 : t, {regs1 = regs2} + {regs1 <> regs2}.
    Proof.
      apply List.list_eq_dec. apply Z.eq_dec.
      (* induction regs1. *)
      (* - destruct regs2. *)
      (*   + auto. *)
      (*   + right. intro H. inversion H. *)
      (* - destruct regs2. *)
      (*   + right. intro H. inversion H. *)
      (*   + destruct (Z.eqb a v) eqn:Hh. *)
      (*     * rewrite Z.eqb_eq in Hh. rewrite Hh. *)
      (*       destruct IHregs1 with (regs2:=regs2). *)
      (*       left. apply f_equal. apply e. *)
      (*       right. intro H. apply n. inversion H. reflexivity. *)
      (*     * right. intro H. inversion H. rewrite <- Z.eqb_eq in H1. *)
      (*       rewrite Hh in H1. inversion H1. *)
    Defined.


    Include HasUsualEq <+ UsualIsEq.

  End RegisterFile.


  Module ISA.
    
    Inductive binop : Type :=
    | Addition : binop
    | Subtraction : binop
    | Multiplication : binop
    | Equality : binop
    | Leq : binop
    | BitwiseOr : binop
    | BitwiseAnd : binop
    | ShiftLeft : binop.
  
    Inductive instr : Set :=
    | INop : instr
    (* register operations *)
    | IConst : value -> Register.t -> instr
    | IMov : Register.t -> Register.t -> instr
    | IBinOp : binop -> Register.t -> Register.t -> Register.t -> instr
    (* memory operations *)
    | ILoad : Register.t -> Register.t -> instr
    | IStore : Register.t -> Register.t -> instr
    (* conditional and unconditional jumps *)
    | IBnz : Register.t -> immediate -> instr
    | IJump : Register.t -> instr
    | IJal : address -> instr
    (* termination *)
    | IHalt : instr.

    Definition eqb_op (op1 op2 : binop) :=
      match (op1,op2) with
        | (Addition,Addition) => true
        | (Subtraction,Subtraction) => true
        | (Multiplication,Multiplication) => true
        | (Equality,Equality) => true
        | (Leq,Leq) => true
        | (BitwiseOr,BitwiseOr) => true
        | (BitwiseAnd,BitwiseAnd) => true
        | (ShiftLeft,ShiftLeft) => true
        | _ => false
      end.

    Definition eqb_instr (i1 i2 : instr) : bool :=
      match (i1,i2) with
      | (INop,INop) => true
      | (IConst v1 r1, IConst v2 r2) => (Z.eqb v1 v2)
                                          && (Register.eqb_reg r1 r2)
      | (IMov r11 r12, IMov r21 r22) =>
        (Register.eqb_reg r11 r22)
          && (Register.eqb_reg r21 r22)
      | (IBinOp op1 r11 r12 r13, IBinOp op2 r21 r22 r23) =>
        (eqb_op op1 op2)
          && (Register.eqb_reg r11 r21)
          && (Register.eqb_reg r12 r22)
          && (Register.eqb_reg r13 r23)
      | (ILoad r11 r12, IMov r21 r22) =>
        (Register.eqb_reg r11 r21)
          && (Register.eqb_reg r12 r22)
      | (IStore r11 r12, IMov r21 r22) =>
        (Register.eqb_reg r11 r21)
          && (Register.eqb_reg r21 r22)
      | (IBnz r1 imm1, IBnz r2 imm2) =>
        (Register.eqb_reg r1 r2)
          && (Z.eqb imm1 imm2)
      | (IJump r1, IJump r2) => (Register.eqb_reg r1 r2)
      | (IJal a1, IJal a2) => (N.eqb a1 a2)
      | (IHalt, IHalt) => true
      | _ => false
      end.

    Theorem instr_eq_dec:
      forall i1 i2 : instr,  {i1 = i2} + {i1 <> i2}.
    Proof.
      repeat decide equality. Defined.
    
  End ISA.

  
  Inductive word := 
  | Data : value -> word
  | Instruction : ISA.instr -> word.

  
  Module Memory.

    Definition t := BinNatMap.t word.

    Definition get_word (mem : t) (ptr : address) : option word :=
      BinNatMap.find ptr mem.

    Definition get_value (mem : t) (ptr : address) : option value :=
      match get_word mem ptr with
      | Some (Data val) => Some val
      | _ => None (* might need to deal with an instruction here*) 
      end.

    
    Definition set_value (mem : t) (ptr : address) (val : value) : t :=
      BinNatMap.add ptr (Data val) mem.

    Definition set_instr (mem : t) (ptr : address) (i : ISA.instr) : t :=
      BinNatMap.add ptr (Instruction i) mem.


    Definition to_address (ptr:value) : address :=
      (* negatives are converted to zero *)
      Z.to_N ptr.

    Definition empty : t := BinNatMap.empty word.

    Definition get_used_addresses (mem : t) :=
      BinNatMap.fold (fun key elt acc => key::acc) mem nil.

    Definition filter_used_addresses (mem : t) (filter : address -> bool) :=
      BinNatMap.fold (fun key elt acc =>
                        if (filter key)
                        then key::acc
                        else acc)
                     mem nil.
      
    Definition equal (m1 m2 : t) : bool :=
      let aux w1 w2 :=
          match (w1,w2) with
          | (Data v1, Data v2) => Z.eqb v1 v2
          | (Instruction i1, Instruction i2) => ISA.eqb_instr i1 i2
          | _ => false
          end in
      BinNatMap.equal aux m1 m2.
               
  End Memory.


  Definition executing_binop (op : ISA.binop)
             (op1 : value) (op2 : value) : value :=
    match op with
    | ISA.Addition => op1 + op2
    | ISA.Subtraction => op1 - op2
    | ISA.Multiplication => op1 * op2
    | ISA.Equality => if Zeq_bool op1 op2 then 1 else 0
    | ISA.Leq => if Zle_bool op1 op2 then 1 else 0
    | ISA.BitwiseAnd => Z.land op1 op2
    | ISA.BitwiseOr => Z.lor op1 op2
    | ISA.ShiftLeft => Z.shiftl op1 op2
  end.
  
  Definition executing (mem : Memory.t) (pc : address) ( i : ISA.instr) : Prop :=
    match (Memory.get_word mem pc) with
    | Some (Instruction i') => i = i'
    |  _ => False
    end.


  Definition inc_pc (a : pc) : pc := N.add a 1.

  
End RiscMachine.


Close Scope Z_scope.

(******************************************
 * Program Definition
 *******************************************)
Module SFIComponent.

  Definition id := N.

End SFIComponent.

Module Env  <: UsualDecidableType.

  (* list of dimension COMP_MAX + 1 *)
  Definition CN := list Component.id.

  (* E is a partial map from addresses to procedure names.*)
  Definition E := list (RiscMachine.address*Procedure.id).

  Definition t := CN * E.

  Definition get_component_name_from_id (id : SFIComponent.id)
             (G : t): option Component.id :=
    ListUtil.get (N.to_nat id) (fst G).

  Definition get_procedure (addr : RiscMachine.address)
             (G : Env.t) : option Procedure.id :=
    ListUtil.get_by_key (N.eqb) addr (snd G).
  
  Definition eq_dec:
    forall g1 g2 : t,  {g1 = g2} + {g1 <> g2}.
  Proof.
    repeat decide equality. Defined.

  Include HasUsualEq <+ UsualIsEq.
  
End Env.


Module SFI.

  (* Number of bits used for offset within slot *)
  Definition OFFSET_SIZE:N := 12.

  Definition CID_SIZE:N := 2.
  
  Definition COMPONENT_MASK : N := 2^CID_SIZE - 1.

  Definition CODE_DATA_BIT_MASK : N :=  N.shiftl 1 (OFFSET_SIZE + CID_SIZE).
  

  (* Maximum number of components *)
  Definition COMP_MAX:N := 2^CID_SIZE.


  Definition C_SFI (addr : RiscMachine.address) : SFIComponent.id  := 
    N.land (N.shiftl addr OFFSET_SIZE) COMPONENT_MASK.

  Record program :=
    {
      cn : Env.CN;
      e : Env.E;
      mem : RiscMachine.Memory.t;
      prog_interface : Program.interface
    }.

  Open Scope N_scope.
  Definition get_max_offset : N := 2^OFFSET_SIZE-1.
  Definition address_of (cid : SFIComponent.id) (bid off: N) : RiscMachine.address :=
    bid * 2^(CID_SIZE+OFFSET_SIZE)+cid*2^OFFSET_SIZE+off.
  Close Scope N_scope.
  
  Definition is_same_component (addr1: RiscMachine.address)
             (addr2: RiscMachine.address) : Prop :=
    (C_SFI addr1) = (C_SFI addr2).

  
  Definition is_same_component_bool (addr1: RiscMachine.address)
             (addr2: RiscMachine.address) :=
    N.eqb (C_SFI addr1) (C_SFI addr2).
  


  Definition is_code_address  (addr : RiscMachine.address) : bool :=
    N.eqb (N.land addr CODE_DATA_BIT_MASK) N0.


  Definition is_data_address  (addr : RiscMachine.address) : bool :=
    negb (is_code_address addr).


End SFI.

Module MachineState.

  Definition t := RiscMachine.Memory.t * RiscMachine.pc * RiscMachine.RegisterFile.t.

  Definition getMemory (st : t) : RiscMachine.Memory.t := fst (fst st).

  Definition getPC (st : t) : RiscMachine.pc := snd (fst st).

  Definition getRegs (st : t) :  RiscMachine.RegisterFile.t := snd st.

  Definition empty : t := (RiscMachine.Memory.empty, RiscMachine.PC0,
                           RiscMachine.RegisterFile.reset_all).

End MachineState.


