(**************************************************
 * Author: Ana Nora Evans (ananevans@virginia.edu)
 **************************************************)
Require Import Coq.NArith.BinNat.
Require Import Coq.Lists.List.
Require Import Coq.Numbers.Natural.Peano.NPeano.

Require Import Common.Maps.
Require Import Common.Definitions.
Require Import Intermediate.Machine.
Require Import TargetSFI.Machine.
Require Import CompEitherMonad.
Require Import CompStateMonad.
Require Import I2SFI.AbstractMachine.

Require Import TargetSFI.SFIUtil.

Require Import Coq.Strings.String.

Import MonadNotations.
Open Scope monad_scope.

Definition newline := String "010" ""%string.

(******* Compiler Environment ************)

Record compiler_env : Type := 
  {
    current_component : Component.id;
    next_label : N;
    (* Compoent.id -> Procedure.id -> label for call translation *)
    (* used in procedure generation and ICall translation *)
    exported_procedures_labels : (PMap.t (PMap.t  AbstractMachine.label));
    (* intermediate compoent id to sfi compoent id *)
    cid2SFIid : PMap.t SFIComponent.id;
    (* intermediate component id -> block id -> sfi slot id *)
    (* this is especially needed for static buffers *)
    buffer2slot : PMap.t (PMap.t N);
    (* cid -> pid -> slot *)
    procId2slot : (PMap.t (PMap.t N))
  }.

Notation COMP := (CompStateMonad.t compiler_env).
Notation get := (CompStateMonad.get compiler_env).
Notation put := (CompStateMonad.put compiler_env).
Notation modify := (CompStateMonad.modify compiler_env).
Notation lift := (CompStateMonad.lift compiler_env).
Notation fail := (CompStateMonad.fail compiler_env).
Notation run := (CompStateMonad.run compiler_env).


Definition with_current_component (cid : Component.id)
           (env : compiler_env) :  compiler_env :=
  {|
    current_component := cid;
    next_label := next_label env;
    cid2SFIid := cid2SFIid env;
    exported_procedures_labels := exported_procedures_labels env;
    procId2slot := procId2slot env;
    buffer2slot :=  buffer2slot env
  |}.

Definition env_add_blocks (cid : Component.id) (blocks : PMap.t N)
           (env : compiler_env) :  compiler_env :=
  {|
    current_component := current_component env;
    next_label := next_label env;
    cid2SFIid := cid2SFIid env;
    exported_procedures_labels := exported_procedures_labels env;
    procId2slot := procId2slot env;
    buffer2slot :=  PMap.add cid blocks (buffer2slot env)
  |}.

Definition with_next_label (env : compiler_env) :  compiler_env :=
   {|
    current_component := current_component env;
    buffer2slot :=  buffer2slot env;
    cid2SFIid := cid2SFIid env;
    procId2slot := procId2slot env;
    exported_procedures_labels := exported_procedures_labels env;
    next_label := ((next_label env) + 1)%N
   |}.

(* Helper functions *)
Definition get_proc_label (cid : Component.id) (pid : Procedure.id)
  : COMP (AbstractMachine.label) :=
  do env <- get;
    match (PMap.find cid (exported_procedures_labels env)) with
    | None => fail "Can not find compoent in exported_procedures_labels"
                  (ExportedProcsLabelsC cid (exported_procedures_labels env))
    | Some cprocs =>
      match (PMap.find pid cprocs) with
      | None => fail "Can not find procedure for component in exported_procedures_labels"
                    (ExportedProcsLabelsP cid pid (exported_procedures_labels env))
      | Some res => ret res
      end
    end.


Definition get_sfiId (cid : Component.id) : COMP (SFIComponent.id) :=
  do env <- get;
    (lift (PMap.find cid (cid2SFIid env))
          "Missing component id in cid2SFIid"%string
          (CompEitherMonad.PosArg cid)
    ).

Definition get_SFI_code_address (cid : Component.id) (pid : Procedure.id)
           (offset : nat) : COMP (RiscMachine.address) :=
  do cenv <- get;
    do sfiId <- get_sfiId cid;      
    do cmap <- (lift (PMap.find cid (procId2slot cenv))
       "Missing component id in procId2slot"%string
          (CompEitherMonad.PosArg cid));
    do slotid <- (lift (PMap.find pid cmap)
       "Missing componentprocedure id in procId2slot"%string
       (CompEitherMonad.TwoPosArg cid pid));
    ret (SFI.address_of sfiId slotid (N.of_nat offset)). 

Definition get_data_slotid (cid : Component.id) (bid : Block.id)
  : COMP (N) :=
  do cenv <- get;
  do cmap <- lift (PMap.find cid (buffer2slot cenv))
     "Missing component id in buffer2slot"%string
     (CompEitherMonad.PosArg cid);
    lift (PMap.find bid cmap)
         "Missing block id in buffer2slot"%string
         (CompEitherMonad.TwoPosArg cid bid).
      

Definition get_SFI_data_address (cid : Component.id)
           (bid : Block.id)
           (offset :  Block.offset)
  : COMP (RiscMachine.address) :=
  do cenv <- get;
    do psfiId <- get_sfiId cid;    
     do pslotid <- get_data_slotid cid bid;
    ret (SFI.address_of psfiId pslotid (Z.to_N offset)).
  

(****************** Initial compiler environment *******************)

(***** cn : list of Component.id needed in RiscMachine.progra, *)
Definition gen_cn (pi : Program.interface) : list Component.id :=
  List.map (fun '(key,_) => key) (PMap.elements pi).

Definition exported_procs_labels (procs : PMap.t (PMap.t Intermediate.Machine.code))
           (pi : Program.interface) : PMap.t (PMap.t AbstractMachine.label) :=
  let max_code_component_label procs :=
      N.pos ( List.fold_left
                Pos.max
                (List.map
                   (fun i =>
                      match i with
                      | Intermediate.Machine.ILabel lbl => lbl
                      | _ => 1%positive 
                      end )                  
                      (List.flat_map snd procs)
                )                
                1%positive) in
  
  let component_exported_procs_labels cid pi procs : (PMap.t AbstractMachine.label) :=
      match PMap.find cid pi with
      | None => PMap.empty AbstractMachine.label
      | Some comp_interface =>
        let exp_procs := Component.export comp_interface in
        let start_lbl := ((max_code_component_label procs) + 1)%N in
        let new_labels := List.map N.of_nat (List.seq (N.to_nat start_lbl)
                                                      (List.length exp_procs)) in 
        PMapExtra.of_list (List.combine exp_procs
                                        (List.combine
                                           (List.repeat cid (List.length exp_procs))
                                           new_labels))
      end in
  PMap.fold (fun cid procs_map acc =>
               PMap.add cid
                        (
                          component_exported_procs_labels
                            cid
                            pi
                            (PMap.elements procs_map)
                        )
                        acc
            )
            procs (PMap.empty (PMap.t AbstractMachine.label)).

Fixpoint allocate_procedure_slots (procs : PMap.t (PMap.t Intermediate.Machine.code))
  : PMap.t (PMap.t N) :=

  PMap.mapi (fun cid proc_map =>               
               let pids := (List.map fst (PMap.elements proc_map)) in
                PMapExtra.of_list
                  (List.combine pids (SFI.Allocator.allocate_code_slots (List.length pids)))
            ) procs.

Definition init_env (i_cid2SFIid : PMap.t N) (i_procId2slot : PMap.t (PMap.t N))
           (i_exported_procedures_labels : (PMap.t (PMap.t  AbstractMachine.label)))
           (i_next_label : N)
  : compiler_env :=
  {| current_component := 1%positive;
     next_label := i_next_label;
     buffer2slot := PMap.empty (PMap.t N);
     procId2slot := i_procId2slot;
     exported_procedures_labels := i_exported_procedures_labels;
     cid2SFIid := i_cid2SFIid
  |}.

(**************************** Slot allocation ************************************)

(*
 * buffs: static buffers 
 * Updates environment: sets buffer2slot
 * Returns: memory with data slot 1 reserved for allocator and the static buffers 
 *          preallocated
 *)
Fixpoint allocate_buffers (buffs :  (list (Component.id * (list (Block.id * (nat + list value))))))
  : COMP (RiscMachine.Memory.t) :=
  (* components with static buffers *)
  let allocate_buffers1 buffs := 
      match buffs with
      | [] => ret RiscMachine.Memory.empty
      | (cid,lst) :: xs =>
        do mem <- allocate_buffers xs;
          do sfi_cid <- get_sfiId cid;
          match List.find (fun '(_,size) =>
                             match size with
                             | inl nsz => 
                               Nat.ltb (N.to_nat SFI.SLOT_SIZE) nsz
                             | inr lst =>
                               Nat.ltb (N.to_nat SFI.SLOT_SIZE) (List.length lst)
                             end
                          ) lst
          with
          | None => 
            let blocks := PMapExtra.of_list
                            (List.combine (fst (List.split lst))
                                          (SFI.Allocator.allocate_data_slots
                                             (List.length lst))) in
            do! modify (env_add_blocks cid blocks);

              ret (RiscMachine.Memory.set_value
                     mem
                     (SFI.address_of sfi_cid (SFI.Allocator.allocator_data_slot) 0%N)
                     (SFI.Allocator.initial_allocator_value (List.length lst)))
          |_ => fail "allocate_buffers" NoInfo
          end
      end in
  (* components without static buffers *)
  let fix allocator_init cids mem :=
      match cids with
      | [] => ret mem
      | cid :: xs =>
        do res_mem <- allocator_init xs mem;
          do cenv <- get;
          (* let cid2SFIid := (cid2SFIid cenv) in *)
          do sfi_cid <-  get_sfiId cid;
           ret (RiscMachine.Memory.set_value
                         res_mem
                         (SFI.address_of sfi_cid (SFI.Allocator.allocator_data_slot) 0%N)
                         (SFI.Allocator.initial_allocator_value 0))
      end in
  do mem1 <- allocate_buffers1 buffs;
    (* need the components without static buffers *)
     do cenv <- get;
     allocator_init
       (
         List.filter (fun id => (negb (List.existsb (Pos.eqb id) (List.map fst buffs))))
                     (List.map fst (PMap.elements (cid2SFIid cenv)))
       ) mem1.
    

Fixpoint init_buffers
         (mem : RiscMachine.Memory.t)
         (buffs :  (list (Component.id * (list (Block.id * (nat + list value))))))
  : COMP (RiscMachine.Memory.t) :=

  let fix init_buffer mem sfi_cid slotid vals  : COMP (RiscMachine.Memory.t) := 
      match vals with
      | nil => ret mem
      | (off,imval)::xs =>
        match imval with
        | Int n =>
          init_buffer 
            (RiscMachine.Memory.set_value
               mem
               (SFI.address_of sfi_cid slotid (N.of_nat off)) n )
            sfi_cid slotid xs
        | Ptr p =>
          let cid : Component.id := Pointer.component p in
          let bid : Block.id := Pointer.block p in
          let offset := Pointer.offset p in    
          if (Z.ltb offset 0%Z)
          then fail "init_buffers negative offset for pointer" (TwoPosArg cid bid)
          else
            if (Z.leb (Z.of_N SFI.SLOT_SIZE) offset)
            then
              fail "init_buffers offset too large" (TwoPosArg cid bid)
            else
              do address <- get_SFI_data_address cid bid offset;
              init_buffer 
                (RiscMachine.Memory.set_value
                   mem
                   (SFI.address_of sfi_cid slotid (N.of_nat off))
                   (RiscMachine.to_value address) )
                sfi_cid slotid xs
        | _ => init_buffer mem sfi_cid slotid xs
        end
      end in
                
  let fix init_buffers_comp mem cid (lst : (list (Block.id * (nat + list value))))
      : COMP (RiscMachine.Memory.t) :=
      match lst with
      | nil => ret mem
      | (bid,elt)::xs =>
        match elt with
        | inl _ => ret mem
        | inr vals =>
          do cenv <- get;
            do sfi_cid <- get_sfiId cid;           
            do slotid <- get_data_slotid cid bid;
            do mem' <- init_buffer mem sfi_cid slotid
               (List.combine (List.seq 0 (List.length vals)) vals);
            init_buffers_comp mem' cid xs
        end
      end in
  
  match buffs with
  | [] => ret mem
  | (cid,lst) :: xs =>
      do mem' <- init_buffers_comp mem cid lst;
         init_buffers mem' xs
  end.


(******************************** Instruction translation **************************)

Definition sfi_top_address (rd : RiscMachine.Register.t)
           (cid : SFIComponent.id) : AbstractMachine.code :=
  [
    AbstractMachine.IConst
      (RiscMachine.to_value (SFI.or_data_mask SFI.MONITOR_COMPONENT_ID))
      RiscMachine.Register.R_OR_DATA_MASK
    ; AbstractMachine.IConst
        (RiscMachine.to_value (SFI.OFFSET_BITS_NO + SFI.COMP_BITS_NO + 1%N))
        rd                           
    ; AbstractMachine.IBinOp (RiscMachine.ISA.ShiftLeft) 
                             RiscMachine.Register.R_SFI_SP
                             rd
                             rd                             
    ; AbstractMachine.IBinOp (RiscMachine.ISA.BitwiseOr)
                             rd
                             RiscMachine.Register.R_OR_DATA_MASK
                             rd
    ; AbstractMachine.IConst (RiscMachine.to_value cid)
                           RiscMachine.Register.R_OR_DATA_MASK
  ].


Definition gen_push_sfi (cid : SFIComponent.id) : AbstractMachine.code :=
     (
        (sfi_top_address RiscMachine.Register.R_AUX1 cid)
          ++
          [   
            AbstractMachine.IStore RiscMachine.Register.R_AUX1 RiscMachine.Register.R_RA
            ; AbstractMachine.IConst 1%Z RiscMachine.Register.R_AUX1
            ; AbstractMachine.IBinOp (RiscMachine.ISA.Addition)
                                     RiscMachine.Register.R_SFI_SP
                                     RiscMachine.Register.R_AUX1
                                     RiscMachine.Register.R_SFI_SP
          ]
      ).

Definition gen_pop_sfi (rd : RiscMachine.Register.t) : COMP(AbstractMachine.code) :=
  do cenv <- get;
    do cid <- get_sfiId (current_component cenv);
    do! modify (with_next_label);
    let lbl := ((current_component cenv),(next_label cenv)) in
      ret
        ( [
            AbstractMachine.ILabel lbl
            ; AbstractMachine.IConst 1%Z RiscMachine.Register.R_RA 
            ; AbstractMachine.IBinOp (RiscMachine.ISA.Subtraction)
                                     RiscMachine.Register.R_SFI_SP
                                     RiscMachine.Register.R_RA
                                     RiscMachine.Register.R_SFI_SP
          ]
            ++ (sfi_top_address rd cid)
            ++ 
            [
              AbstractMachine.ILoad RiscMachine.Register.R_RA
                                      RiscMachine.Register.R_RA
            ]
        ).


Definition gen_set_sfi_registers (cid : SFIComponent.id) : AbstractMachine.code :=
  let data_mask := RiscMachine.to_value (SFI.or_data_mask cid) in
  let code_mask := RiscMachine.to_value (SFI.or_code_mask cid) in
  [
      AbstractMachine.IConst data_mask RiscMachine.Register.R_OR_DATA_MASK
    ; AbstractMachine.IConst code_mask RiscMachine.Register.R_OR_CODE_MASK
    ; AbstractMachine.IConst data_mask RiscMachine.Register.R_D
    ; AbstractMachine.IConst code_mask RiscMachine.Register.R_T
  ].

Definition compile_IConst 
           (imval : Intermediate.Machine.imvalue)
           (reg : Intermediate.Machine.register)
  : COMP (AbstractMachine.code) :=
  let reg' : RiscMachine.Register.t := map_register reg in
  match imval with
  | Intermediate.Machine.IInt n => ret [AbstractMachine.IConst n reg']
  | Intermediate.Machine.IPtr p =>
    let cid : Component.id := Pointer.component p in
    let bid : Block.id := Pointer.block p in
    let offset := Pointer.offset p in    
    if (Z.ltb offset 0%Z)
    then fail "compile_IConst negative offset for pointer " (TwoPosArg cid bid)
    else
      if (Z.leb (Z.of_N SFI.SLOT_SIZE) offset)
      then fail "compile_IConst offset too large"  (TwoPosArg cid bid)
      else
        do address <- get_SFI_data_address cid bid offset;
        ret [AbstractMachine.IConst (RiscMachine.to_value address) reg']
  end.

Definition compile_IStore (rp : Intermediate.Machine.register)
           (rs : Intermediate.Machine.register)
  : COMP (AbstractMachine.code) :=
  ret [
      AbstractMachine.IBinOp
        (RiscMachine.ISA.BitwiseAnd)
        (map_register rp)
        (RiscMachine.Register.R_AND_DATA_MASK)
        (RiscMachine.Register.R_D)
      ; AbstractMachine.IBinOp
          (RiscMachine.ISA.BitwiseOr)
          (RiscMachine.Register.R_D)
          (RiscMachine.Register.R_OR_DATA_MASK)
          (RiscMachine.Register.R_D)
      ; AbstractMachine.IStore
          (RiscMachine.Register.R_D)
          (map_register rs)
    ].

Definition compile_IJump (rt : Intermediate.Machine.register)
  : COMP (AbstractMachine.code) :=
  ret [
      AbstractMachine.IBinOp
        (RiscMachine.ISA.BitwiseAnd)
        (map_register rt)
        (RiscMachine.Register.R_AND_CODE_MASK)
        (RiscMachine.Register.R_T)
      ; AbstractMachine.IBinOp
          (RiscMachine.ISA.BitwiseOr)
          (RiscMachine.Register.R_T)
          (RiscMachine.Register.R_OR_CODE_MASK)
          (RiscMachine.Register.R_T)
      ; AbstractMachine.IJump (RiscMachine.Register.R_T)
    ].

Definition compile_IAlloc (rp : Intermediate.Machine.register)
           (rs : Intermediate.Machine.register) : COMP (AbstractMachine.code) :=
  do cenv <- get;
    do cid <- get_sfiId (current_component cenv);
    let rp' := (map_register rp) in
    let rs' := (map_register rs) in
    let (r1,r2) :=
        if (RiscMachine.Register.eqb rp' rs')
        then
          if (RiscMachine.Register.eqb rp' RiscMachine.Register.R_AUX1)
          then (RiscMachine.Register.R_AUX1,RiscMachine.Register.R_AUX2)
          else (rp',RiscMachine.Register.R_AUX1)
        else (rp',rs') in  ret
    [
    (* # save register r₂ at location (s=1,c,o=1) *)
    (*   Const r₁ <- Address of (s=1,cid,o=1)  *)
      AbstractMachine.IConst (RiscMachine.to_value (SFI.address_of cid 1%N 1%N))
                             r1
      (*   Store *r₁ <- r₂ *)
      ; AbstractMachine.IStore r1 r2
      (*   Const r₂ <- Address of (s=1,cid,o=0)  *)
      ; AbstractMachine.IConst (RiscMachine.to_value (SFI.address_of cid 1%N 0%N))
                             r2
      (*   Load *r₂ -> r₁ *)
      ; AbstractMachine.ILoad r2  r1
                             
      (*   Const r₂ <- 1 *)
      ; AbstractMachine.IConst (1%Z) r2

      (*   Binop r₁ <- r₁ + r₂ *)
      ; AbstractMachine.IBinOp (RiscMachine.ISA.Addition) r1  r2  r1
                             
      (*   Const r₂ <- Address of (s=1,cid,o=0)  *)
      ; AbstractMachine.IConst (RiscMachine.to_value (SFI.address_of cid 1%N 0%N))
                             r2
      (*   Store *r₂ <- r₁ *)
      ; AbstractMachine.IStore r2  r1
    
      (* # calculate address (s=2*k+1,c,o=0) in r₁ *)      
      (*   Const r₂ <- N+S+1 *)
      ; AbstractMachine.IConst (RiscMachine.to_value (SFI.OFFSET_BITS_NO + SFI.COMP_BITS_NO + 1%N))
                           r2
      (*   Binop r₁ <- r₁ << r₂ # k shift left (N+S+1) *)
      ; AbstractMachine.IBinOp (RiscMachine.ISA.ShiftLeft) r1  r2  r1
                             
      (*   Binop r₁ <- r₁ |  r_or_data_mask  *)
      ;  AbstractMachine.IBinOp (RiscMachine.ISA.BitwiseOr) r1
                             RiscMachine.Register.R_OR_DATA_MASK r1
      (* # restore r₂ *)
      (*   Const r₂ <- Address of (s=1,cid,o=1)  *)
      ; AbstractMachine.IConst (RiscMachine.to_value (SFI.address_of cid 1%N 1%N))
                               r2
      (*   Load *r₂ -> r₂ *)
      ;  AbstractMachine.ILoad  r2  r2
                               
    ].

Definition compile_IReturn : COMP (AbstractMachine.code) :=
  do res <- gen_pop_sfi RiscMachine.Register.R_RA;
    ret (res
           ++ [
               AbstractMachine.IJump RiscMachine.Register.R_RA]).

Definition compile_ICall (cid1 : Component.id) (pid : Procedure.id)
  : COMP (AbstractMachine.code) :=
  do cenv <- get;
    do cid <- get_sfiId (current_component cenv);
    let data_mask := RiscMachine.to_value (SFI.or_data_mask cid) in
    let code_mask := RiscMachine.to_value (SFI.or_code_mask cid) in
    do clbl <- get_proc_label cid1 pid;
      do! modify (with_next_label);
      let lbl :=  ((current_component cenv),(next_label cenv)) in
        ret [
            AbstractMachine.IJal clbl
            ; AbstractMachine.ILabel lbl (* use this to force the next 4 intruction uninterrupted *)
            ; AbstractMachine.IConst data_mask RiscMachine.Register.R_OR_DATA_MASK
            ; AbstractMachine.IConst code_mask RiscMachine.Register.R_OR_CODE_MASK
            ; AbstractMachine.IConst data_mask RiscMachine.Register.R_D
            ; AbstractMachine.IConst code_mask RiscMachine.Register.R_T
          ].


Fixpoint compile_instructions (ilist : Intermediate.Machine.code)
  : COMP (AbstractMachine.code) :=
  let compile_instruction i :=
      do cenv <- get;
        let cid := (current_component cenv) in
        match i with
        | Intermediate.Machine.INop => ret [AbstractMachine.INop]
        | Intermediate.Machine.ILabel lbl =>
          ret [AbstractMachine.ILabel (cid, N.of_nat (Pos.to_nat lbl))]
        | Intermediate.Machine.IConst imval reg => (compile_IConst imval reg)
        | Intermediate.Machine.IMov rs rd => ret [AbstractMachine.IMov
                                                   (map_register rs)
                                                   (map_register rd)]
        | Intermediate.Machine.IBinOp op r1 r2 rd => ret [AbstractMachine.IBinOp
                                                           (map_binop op)
                                                           (map_register r1)
                                                           (map_register r2)
                                                           (map_register rd)]
        | Intermediate.Machine.ILoad rp rd => ret [AbstractMachine.ILoad (map_register rp)
                                                                        (map_register rd)]
        | Intermediate.Machine.IStore rp rs => (compile_IStore rp rs)
        | Intermediate.Machine.IAlloc rp rs => (compile_IAlloc rp rs)
        | Intermediate.Machine.IBnz r lbl => ret [AbstractMachine.IBnz (map_register r)
                                                                      (cid,N.of_nat (Pos.to_nat lbl))]
        | Intermediate.Machine.IJump rt => (compile_IJump rt)
        | Intermediate.Machine.IJal lbl => ret [AbstractMachine.IJal (cid,N.of_nat (Pos.to_nat lbl))]
        | Intermediate.Machine.ICall c p => (compile_ICall c p)
        | Intermediate.Machine.IReturn => (compile_IReturn)
        | Intermediate.Machine.IHalt => ret [AbstractMachine.IHalt]
        end in
  match (ilist) with
  | [] => ret []
  | i::xs =>
    do ai <- compile_instruction i;
      do res <- compile_instructions xs;
      ret (ai ++ res)
  end.

(* Needs in environment: current_component and all the other fields initialized properly. *) 
Definition compile_procedure 
           (pid : Procedure.id)
           (code : Intermediate.Machine.code)
           (interface : Program.interface) 
  : COMP (AbstractMachine.code) :=
  (* if the procedure is exported then must add the sfi stuff*)
  do cenv <- get;
    let cid := (current_component cenv) in
    do comp_interface <- lift (PMap.find cid interface)
       "Can't find interface for component " (PosArg cid);
      let exported_procs := Component.export comp_interface in
      let is_exported := List.existsb (Pos.eqb pid) exported_procs in
      do acode <- compile_instructions code; 
        if is_exported then          
            do proc_label <- get_proc_label cid pid;
            do sfiId <- get_sfiId cid;
            ret (
                [AbstractMachine.IHalt; AbstractMachine.ILabel proc_label]
                  ++ (gen_push_sfi sfiId) 
                  ++ (gen_set_sfi_registers sfiId)
                  ++ acode )
        else
          ret acode.

Definition check_component_labels (cid : Component.id)
           (procs : list (Procedure.id * AbstractMachine.code))
  : COMP(list (Procedure.id * AbstractMachine.code)) :=
  (* no duplication in labels *)
  (* exported proc label in offset 1 *)
  let check_label_duplication (cid:Component.id) procs :=
      let all_labels :=
          (List.fold_left
             (fun acc linstr =>
                List.fold_left
                  (fun acc' i =>
                     match i with
                     | AbstractMachine.ILabel l => l::acc'
                     | _ => acc'
                     end
                  )
                  linstr acc                                                                   
             )
             procs [] )
      in
      if (Nat.eqb (List.length all_labels)
                  (List.length (List.nodup label_eq_dec all_labels)))
      then ret procs
      else fail " check_component_labels::label duplication in component" NoInfo
  in
      
  let check_procedure cid pid acode :=      
      match acode with
      | _::(AbstractMachine.ILabel _)::_ => ret procs
      | _ => fail " check_component_labels::procedure label not found at offset" NoInfo
      end in
  
  let fix check_component cid procs :=
      match procs with
      | nil => ret procs
      | (pid,acode)::xs =>
        do x <- check_procedure cid pid acode;
          check_component cid xs
      end in

  check_component cid procs.


Fixpoint compile_components (components : list (Component.id * PMap.t Intermediate.Machine.code))
         (interface : Program.interface)
  : COMP (list (Component.id * PMap.t AbstractMachine.code)) :=

  let fix compile_procedures procs interface :=
      match procs with
      | [] => ret []
      | (pid,code) :: xs =>
        do compiled_proc <- compile_procedure pid code interface;
          do res <- compile_procedures xs interface;
          ret ((pid, compiled_proc)::res)
      end in
  
  match components with
  | [] => ret []
  | (cid,procs)::xs =>
    do! modify (with_current_component cid);
      do procs <- compile_procedures (PMap.elements procs) interface;
      do x <- check_component_labels cid procs;
      do res <- compile_components xs interface;
      ret ((cid, PMapExtra.of_list procs)::res)
  end.

(*************** Code Alligment and ILabel Removal  *******************)
(* 
use crt to go over list 
- drop last ILabel from proc
- if crt is not ILabel, copy and move on
- if crt is ILabel
  if crt address is okay add pair (label,address) to the list
  if not padd with INop until address okay and do the above
*)
Definition layout_procedure
           (cid : Component.id)
           (pid : Procedure.id)
           (plbl : AbstractMachine.label)
           (code : AbstractMachine.code)
  : ( AbstractMachine.lcode) :=
  let padd acc elt :=
      (* must padd *)
      (* padd code_lst up to a multiple of SFI.BASIC_BLOCK_SIZE *)
      let r := N.modulo (N.of_nat (List.length acc))
                        SFI.BASIC_BLOCK_SIZE in
      let p := N.modulo (SFI.BASIC_BLOCK_SIZE - r)%N
                        SFI.BASIC_BLOCK_SIZE in
      acc
        ++ (List.repeat
              (None,AbstractMachine.INop)
              (N.to_nat p))
        ++ [elt] in
  
  (* accumulate labels *)
  let lcode1 :=
      List.map
        (fun '(ll,i) =>
           match ll with
           | nil => (None,i)
           | _ => (Some ll,i)
           end
        )           
        (snd ( List.fold_left
            (fun acc elt =>
               let '(current_labels,lcode) := acc in
               match elt with
               | AbstractMachine.ILabel lbl => (current_labels++[lbl],lcode)
               | _ => (nil,lcode ++ [(current_labels,elt)])
               end
            ) code (nil,nil)
        )) in
  (* padding *)
      List.fold_left
         (fun acc elt =>       
            match elt with
            | (None, i) => acc ++ [elt]
            | (Some ll, i) =>
              match ll with
              | nil => acc ++ [elt]
              | lbl::nil =>
                if (label_eqb lbl plbl)
                then
                  acc ++ [elt]
                else
                  padd acc elt
              | _ =>  padd acc elt
                
              end
            end
         ) lcode1 nil.


Definition check_label_duplication (cid:Component.id)
           (procs : PMap.t AbstractMachine.lcode) :=
  let all_labels :=
      (PMap.fold
         (fun pid lcode acc =>
            List.fold_left
              (fun acc' linstr =>
                 match linstr with
                 | (Some ll,_) => acc'++ll
                 | (None,_) => acc'
                 end)
              lcode acc
         ) procs []) in
  Nat.eqb (List.length all_labels)
          (List.length (List.nodup label_eq_dec all_labels)).
         

Definition check_labeled_code ( labeled_code : (PMap.t (PMap.t AbstractMachine.lcode)))
  : COMP( (PMap.t (PMap.t AbstractMachine.lcode)) ) :=
  let check_procedure cid pid lcode :=
      do l <- get_proc_label cid pid;        
        match lcode with
        | _::(Some [lbl],_)::_ => ret  labeled_code
        | _ => fail " check_labeled_code::procedure label not found at offset "
                   (DuplicatedLabels labeled_code)
        end in
  let fix check_component cid procs :=
      match procs with
      | nil => ret  labeled_code
      | (pid,lcode)::xs =>
        do x <- check_procedure cid pid lcode;
          check_component cid xs
      end in
  let fix check_progr comps :=
      match comps with
      | nil => ret  labeled_code
      | (cid,comp)::xs =>
        do x <- check_component cid (PMap.elements comp);
          if (check_label_duplication cid comp)
          then
            check_progr xs
          else
            fail " check_labeled_code::label duplication in component "
                 (DuplicatedLabels labeled_code)
      end in
  check_progr (PMap.elements labeled_code).


(* acode: cid -> pid -> list of instr (labeled individually) *)
Definition layout_code (acode : PMap.t (PMap.t AbstractMachine.code))
           (* association list of (cid,label) -> (pid, offset of label) *)
  : (* new code with ILabel removed and INop introduced such that the 
       contraints are satisfied for jump targets *)
    COMP (PMap.t (PMap.t AbstractMachine.lcode)) :=
  
  let fix layout_procedures cid  lst : COMP (PMap.t AbstractMachine.lcode) :=
        match lst with
        | [] => ret (PMap.empty AbstractMachine.lcode)
        | (pid,code)::xs =>
          do res_map <- layout_procedures cid xs;
              do plbl <- (get_proc_label cid pid);
            let acode := layout_procedure cid pid plbl code in
            ret (PMap.add pid acode res_map)
        end
  in
  let fix aux lst : COMP (PMap.t (PMap.t AbstractMachine.lcode)) :=
      match lst with
      | [] => ret (PMap.empty (PMap.t AbstractMachine.lcode))
      | (cid,procs_map)::xs =>
        do cenv <- get;
          do res_map <- aux xs;
          do proc_res <- layout_procedures cid (PMap.elements procs_map); 
          ret (PMap.add cid proc_res res_map)
      end
  in
  do lcode <- aux (PMap.elements acode);
    check_labeled_code lcode.




(********************* Generate code memory and E **********************)

Definition index_of (lbl : AbstractMachine.label) (listing : AbstractMachine.lcode) : nat :=
  fst (List.fold_left (fun '(index,found) '(crt_lbls,_) =>
                    if (eqb found false)
                    then
                      match crt_lbls with
                      | None => ((index+1)%nat,false)
                      | Some llst => 
                        if (List.existsb  (label_eqb lbl) llst)
                        then ((index)%nat,true)
                        else ((index+1)%nat,false)
                      end
                    else (index,found)) listing (0%nat,false)).
  
  
Definition get_E (lcode : PMap.t (PMap.t AbstractMachine.lcode)) : COMP (Env.E) :=
  
  let fix fold_procs cid procs_lst acc :=
      do cenv <- get;
      match procs_lst with
      | [] => ret acc
      | (pid,lbl) :: xs =>        
        match PMap.find cid lcode with
        | None => fail "get_E did not find component in lcode" (PosArg cid)
        | Some procs_lmap =>
          match PMap.find pid procs_lmap with
          | None => fail "get_E did not find procedure in lcode" (TwoPosArg cid pid)
          | Some listing =>
            let i := index_of lbl listing in
            if (ltb i (List.length listing))
            then
              do address <- get_SFI_code_address cid pid i;
                (fold_procs cid xs ((address,pid)::acc))
            else fail "get_E the label exported by this procedure is not found in the listing"
                      (TwoPosArg cid pid)
          end
        end
      end in
        
  let fix fold_comp (clist : list (Component.id*PMap.t label))
          (acc : Env.E)  : COMP (Env.E) :=      
      match clist with
      | [] => ret acc
      | (cid,pmap)::xs =>
        do res <- fold_procs cid (PMap.elements pmap) [];
          fold_comp xs (acc++res)
      end in
  do cenv <- get;
  fold_comp (PMap.elements (exported_procedures_labels cenv)) [].

(**************************** label 2 address ****************************)

Definition label2address (lc : PMap.t (PMap.t AbstractMachine.lcode))
  : COMP (PMap.t (PMap.t (list (AbstractMachine.label * RiscMachine.address)))) :=

  let fix fold_instr cid pid list_instr
          (acc : list (AbstractMachine.label * RiscMachine.address)) :=
      match list_instr with
      | [] => ret acc
      | (i,(None,_))::xs => fold_instr cid pid xs acc
      | (i,(Some lbls,_))::xs => 
        do address <- get_SFI_code_address cid pid i;
          fold_instr cid pid xs (acc++(List.combine
                                         lbls
                                         (List.repeat address (List.length lbls))))
      end in
  
  let fix fold_procs cid procs_lst
          (acc : (PMap.t (list (AbstractMachine.label * RiscMachine.address)))) :=
      do cenv <- get;
      match procs_lst with
      | [] => ret acc
      | (pid,proc_lcode) :: xs =>
        do res <- fold_instr cid pid
           ( List.combine
               (List.seq 0%nat (List.length proc_lcode))
               proc_lcode )
           [];
          fold_procs cid xs (PMap.add pid res acc)
      end in
        
  let fix fold_comp (clist : list (Component.id*(PMap.t AbstractMachine.lcode)))
          (acc : (PMap.t (PMap.t (list (AbstractMachine.label * RiscMachine.address))))) :=      
      match clist with
      | [] => ret acc
      | (cid,pmap)::xs =>
        do res <- fold_procs cid (PMap.elements pmap)
           (PMap.empty (list (AbstractMachine.label * RiscMachine.address)));
          fold_comp xs (PMap.add cid res acc)
      end in
  
    fold_comp (PMap.elements lc)
              (PMap.empty (PMap.t (list (AbstractMachine.label * RiscMachine.address)))).


(*************************** Monitor component ****************************************)

Definition get_address (cid : Component.id)
           (pid : Procedure.id)
           (lbl : AbstractMachine.label)
           (l2a :  (PMap.t (PMap.t (list (AbstractMachine.label * RiscMachine.address)))))
  : COMP (RiscMachine.address) :=
  do pmap <- lift (PMap.find cid l2a) "get_address:No cid" (PosArg cid);
    do pl <- lift (PMap.find pid pmap) "get_address:No pid" (TwoPosArg cid pid);
    match (List.find (fun '(l,a) => AbstractMachine.label_eqb l lbl) pl) with
    | None => fail "get_address:Address not found" NoInfo
    | Some (_,a) => ret a
    end.

Definition  get_address_by_label
            (lbl : AbstractMachine.label)
            (l2a :  (PMap.t (PMap.t (list (AbstractMachine.label * RiscMachine.address)))))
  : COMP (RiscMachine.address) :=

  let ll := List.concat 
              (List.flat_map (fun pmap => List.map snd (PMap.elements pmap))
                          (List.map snd (PMap.elements l2a)) (* list of PMap *))
  in match (List.find (fun '(l,a) => AbstractMachine.label_eqb l lbl) ll) with
     | None => fail "get_address_by_label" NoInfo
     | Some (_,a) => ret a
     end.

Definition generate_comp0_memory (main : Component.id * Procedure.id)
           (mem : RiscMachine.Memory.t)
           (l2a :  (PMap.t (PMap.t (list (AbstractMachine.label * RiscMachine.address)))))
: COMP (RiscMachine.Memory.t) :=
  do main_label <- get_proc_label (fst main) (snd main);
  do main_address <- get_address (fst main) (snd main) main_label l2a;
  let mem0 := RiscMachine.Memory.set_instr
                mem
                (SFI.address_of SFI.MONITOR_COMPONENT_ID 0 0)
                (RiscMachine.ISA.IConst 0%Z RiscMachine.Register.R_SFI_SP) in
  let mem1 := RiscMachine.Memory.set_instr
                mem0
                (SFI.address_of SFI.MONITOR_COMPONENT_ID 0 1)
                (RiscMachine.ISA.IConst
                   (RiscMachine.to_value SFI.AND_DATA_MASK)
                   RiscMachine.Register.R_AND_DATA_MASK) in
  let mem2 := RiscMachine.Memory.set_instr
                mem1
                (SFI.address_of SFI.MONITOR_COMPONENT_ID 0 2)
                (RiscMachine.ISA.IConst
                   (RiscMachine.to_value SFI.AND_CODE_MASK)
                   RiscMachine.Register.R_AND_CODE_MASK) in
  let mem3 := RiscMachine.Memory.set_instr
                mem2
                (SFI.address_of SFI.MONITOR_COMPONENT_ID 0 3)
                (RiscMachine.ISA.IConst
                   1%Z
                   RiscMachine.Register.R_ONE) in
  let mem4 := RiscMachine.Memory.set_instr
                mem3
                (SFI.address_of SFI.MONITOR_COMPONENT_ID 0 4)
                (RiscMachine.ISA.IJal main_address) in
  ret (RiscMachine.Memory.set_instr
                mem4
                (SFI.address_of SFI.MONITOR_COMPONENT_ID 0 5)
                (RiscMachine.ISA.IHalt)).


(*************************** Code Memory *******************************)

Definition generate_instruction
           (cid : Component.id)
           (pid : Procedure.id)
           (li :(option (list AbstractMachine.label)) * AbstractMachine.ainstr)
           (l2a : (PMap.t (PMap.t (list (AbstractMachine.label * RiscMachine.address)))))
           (offset : nat)
           (mem0 : RiscMachine.Memory.t) : COMP (RiscMachine.Memory.t) :=
  do address <-  get_SFI_code_address cid pid offset;
  let (_,i) := li in
  match i with
  | AbstractMachine.INop => ret (RiscMachine.Memory.set_instr
                                  mem0 address 
                                  RiscMachine.ISA.INop)
  | AbstractMachine.IConst v r => ret (RiscMachine.Memory.set_instr
                                  mem0 address 
                                  (RiscMachine.ISA.IConst v r))
  | AbstractMachine.IMov r1 r2 => ret (RiscMachine.Memory.set_instr
                                  mem0 address 
                                  (RiscMachine.ISA.IMov r1 r2))
  |  AbstractMachine.IBinOp op r1 r2 r3 => ret (RiscMachine.Memory.set_instr
                                                 mem0 address 
                                                 (RiscMachine.ISA.IBinOp op r1 r2 r3))
  | AbstractMachine.ILoad r1 r2 => ret (RiscMachine.Memory.set_instr
                                  mem0 address 
                                  (RiscMachine.ISA.ILoad r1 r2))
  | AbstractMachine.IStore r1 r2 => ret (RiscMachine.Memory.set_instr
                                  mem0 address 
                                  (RiscMachine.ISA.IStore r1 r2))
  | AbstractMachine.IJump r => ret (RiscMachine.Memory.set_instr
                                  mem0 address 
                                  (RiscMachine.ISA.IJump r))
  | AbstractMachine.IBnz r lbl =>
    (* brach should be allowed only in the current procedure *)
    do target_address <- get_address cid pid lbl l2a;
      let branch_offset := ((Z.of_N target_address) - (Z.of_N address))%Z in
      ret (RiscMachine.Memory.set_instr
             mem0 address 
             (RiscMachine.ISA.IBnz r branch_offset))
  | AbstractMachine.IJal lbl =>
    do new_address <- get_address_by_label lbl l2a;
      ret (RiscMachine.Memory.set_instr
             mem0 address 
             (RiscMachine.ISA.IJal new_address))
  | AbstractMachine.IHalt => ret (RiscMachine.Memory.set_instr
                                  mem0 address 
                                  RiscMachine.ISA.IHalt)
    
  | _ => fail "generate_instruction"  NoInfo
  end.

Definition generate_procedure_code
           (cid : Component.id)
           (pid : Procedure.id)
           (linstrs : lcode)
           (l2a : (PMap.t (PMap.t (list (AbstractMachine.label * RiscMachine.address)))))
           (mem0 : RiscMachine.Memory.t) : COMP (RiscMachine.Memory.t) :=
    let fix aux lst acc :=
        let '(index,mem) := acc in
        match lst with
        | [] => ret acc
        | i::xs =>
          do res <- generate_instruction cid pid i l2a index mem;
          aux xs ((index+1)%nat,res)
        end in
    do res <- (aux linstrs (0%nat,mem0));
      ret (snd res).
        
Definition generate_component_code
           (cid : Component.id)
           (pmap : PMap.t lcode)
           (l2a : (PMap.t (PMap.t (list (AbstractMachine.label * RiscMachine.address)))))
           (mem0 : RiscMachine.Memory.t) : COMP (RiscMachine.Memory.t) :=
  let fix aux (lst : list (Procedure.id * lcode)) acc :=
      match lst with
      | [] => ret acc
      | (pid,linstrs)::xs =>
        do res <- generate_procedure_code cid pid linstrs l2a acc;
          aux xs res
      end in aux (PMap.elements pmap) mem0.

Definition generate_code_memory
           ( labeled_code : (PMap.t (PMap.t lcode)))
           (l2a :  (PMap.t (PMap.t (list (AbstractMachine.label * RiscMachine.address)))))
           (mem0 : RiscMachine.Memory.t) : COMP (RiscMachine.Memory.t) :=
  let fix aux lst acc  :=
      match lst with
      | [] => ret acc
      | (cid,pmap) :: xs =>
        do res <- generate_component_code cid pmap l2a acc;
          aux xs res
      end in aux (PMap.elements labeled_code) mem0.
      
      
Definition compile_program (ip : Intermediate.program) :=
  let cn := gen_cn (Intermediate.prog_interface ip) in
  let cid2SFIid := List.fold_left
                     (fun acc '(cid,i)  =>
                        PMap.add cid (Env.index2SFIid i) acc)
                     (List.combine cn (List.seq 0 (List.length cn)))
                     (PMap.empty SFIComponent.id) in
  let procs_labels := exported_procs_labels (Intermediate.prog_procedures ip)
                                            (Intermediate.prog_interface ip) in
  let max_label := List.fold_left
                     N.max
                     (List.flat_map
                        (fun m => List.map (fun '(_,(_,l)) => l) (PMap.elements m))
                        (List.map snd (PMap.elements procs_labels)))
                     1%N in
  
  let procId2slot := allocate_procedure_slots (Intermediate.prog_procedures ip) in

  
  run (init_env cid2SFIid procId2slot procs_labels (max_label+1)%N)
        (
         
          do data_mem' <- allocate_buffers
             (PMap.elements (Intermediate.prog_buffers ip));

            do data_mem <- init_buffers data_mem'
               (PMap.elements (Intermediate.prog_buffers ip));
            
            do acode <- compile_components
               (PMap.elements (Intermediate.prog_procedures ip) )
               (Intermediate.prog_interface ip);
            
            do labeled_code  <- layout_code (PMapExtra.of_list acode);

            do e <- get_E labeled_code;

            do l2a <- label2address labeled_code;

            do mem0 <- generate_comp0_memory (Intermediate.prog_main ip) data_mem l2a;

            do mem <- generate_code_memory labeled_code l2a mem0;
            
            ret {| TargetSFI.Machine.cn := cn;
                   TargetSFI.Machine.e := e;
                   TargetSFI.Machine.mem := mem;
                   TargetSFI.Machine.prog_interface := Intermediate.prog_interface ip;
                |}
            
    ).

(* layout code in memory *)
(* replace labels with addresses *)
(* generate code for component 0
       push address of halt on sfi stack
       call main === changes mem *)
(* generate E *)