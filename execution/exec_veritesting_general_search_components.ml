module V = Vine
module VOpt = Vine_opt

open Exec_exceptions
open Exec_options
open Frag_simplify
open Fragment_machine
open Exec_run_common

type pointer_statements = {
  eip : int64;
  vine_stmts : V.stmt list;
}
  
type breakloop = {
  source_eip : int64;
  dest_eip : int64;
}

type veritesting_data = 
| BreakLoop of breakloop         (* loops in program *)
| InternalLoop of int64          (* loops in vine's decoding of an instruction *)
| Return of int64
| Halt of int64
| FunCall of int64
| SysCall of pointer_statements
| Instruction of pointer_statements


type node = {
  data : veritesting_data;
  mutable parent : node list;
  mutable children : node list;
}

type vineLabel =
| X86eip of int64
| Internal of int

exception UnexpectedEIP


let veritesting_data_to_string = function
  | BreakLoop at  -> (Printf.sprintf "BreakLoop From 0x%LX To 0x%LX"
			at.source_eip at.dest_eip)
  | InternalLoop at -> Printf.sprintf "Instruction @ 0x%LX has self loop" at
  | SysCall at -> Printf.sprintf "SysCall @ 0x%LX" at.eip
  | Return at -> Printf.sprintf "Return @ 0x%LX" at
  | Halt at ->  Printf.sprintf "Halt @ 0x%LX" at
  | FunCall at ->  Printf.sprintf "Fun. Call @ 0x%LX" at 
  | Instruction i -> (Printf.sprintf "@ 0x%LX" i.eip)


let node_to_string (node : node) =
  veritesting_data_to_string node.data


let decode_eip str =
  if (str.[0] = 'L' && str.[1] = '_')
  then (let num = String.sub str 2 ((String.length str) - 2) in
	Internal (int_of_string num))
  else X86eip (label_to_eip str)


let check_label label seen_labels = 
  match decode_eip label with 
  | X86eip(_) -> true
  | Internal(ilabel) -> 
    if (List.mem ilabel seen_labels)
    then false
    else true


let walk_to_label target_label tail =
  let rec walk_to_label_help target_label = function
    | [] -> None
    | V.ExpStmt(V.Name(label))::tail ->
      begin
        match decode_eip label with
        | X86eip(_) -> raise UnexpectedEIP
        | Internal(ilabel) ->
          if (target_label = ilabel)
	  then Some tail
          else walk_to_label_help target_label tail
      end
    | _::tail ->
      walk_to_label_help target_label tail in 
  match (decode_eip target_label) with
  | X86eip(_) -> raise UnexpectedEIP
  | Internal(ilabel) -> walk_to_label_help ilabel tail


let equal (a : veritesting_data) (b : veritesting_data) =
  let rec check_vine_stmts = function
    | [], [] -> true
    | _::_, []
    | [], _::_ -> false
    | hd1::tl1, hd2::tl2 ->
      hd1 = hd2 && check_vine_stmts (tl1,tl2) in
  match (a,b) with
  | BreakLoop i1, BreakLoop i2 -> ((i1.source_eip = i2.source_eip)
				   && (i1.dest_eip = i2.dest_eip))
  | InternalLoop i1 , InternalLoop i2
  | Return i1, Return i2
  | Halt i1, Halt i2
  | FunCall i1, FunCall i2 -> i1 = i2
  | SysCall i1, SysCall i2
  | Instruction i1, Instruction i2 ->
    (i1.eip = i2.eip) && check_vine_stmts (i1.vine_stmts, i2.vine_stmts)
  | _, _ -> false


let ordered_p (a : veritesting_data) (b : veritesting_data) =
  match a,b with
  | Instruction i1, Instruction i2 -> i1.eip < i2.eip
  | _, Instruction _ ->  false
  | Instruction _, _ -> true
  | _ , _ -> true

let ordered_p (a : node) (b : node) =  ordered_p a.data b.data
    

let key (a : node) = a.data

let check_cycle (lookfor : node) (root : node) =
  let me = key lookfor in 
  let check_this_gen found_cycle child =
    if not found_cycle
    then (equal me (key child))
    else found_cycle in
  let rec check_cycle_int next =
    (List.fold_left check_this_gen false next.children)
  || List.fold_left
      (fun accum child ->
	if accum
	then accum
	else check_cycle_int child) false next.parent in
  check_cycle_int root
    

let expand fm gamma (node : veritesting_data) =
  match node with
  | InternalLoop _
  | BreakLoop _
  | SysCall _
  | Return _
  | Halt _
  | FunCall _ -> [] (* these are non child-bearing nodes *)
  | Instruction i1 ->
    let _, statement_list = decode_insn_at fm gamma i1.eip in
  (* right now the legality check is going to catch self loops inside
     of the statement list, so I'm not looking for them here.
     Instead, we're just collecting exit points for the region
     and statement lists executed up until that point. *)
    let rec walk_statement_list accum = function
      | [] -> [ Instruction {eip = Int64.add i1.eip Int64.one;
			     vine_stmts = accum;}]
      | stmt::tl ->
	begin
	  match stmt with
          | V.Jmp(V.Name(label)) ->
	    begin
	      match decode_eip label with
	    | X86eip value -> [Instruction {eip = value;
					    vine_stmts = accum }]
	    | Internal value -> 
	      (* if we walk off, it should be because the label is
		 behind us iff labels are only valid local to a vine
		 decoding *)
	      begin
		match walk_to_label label tl with
		| None -> [InternalLoop i1.eip]
		| Some next -> walk_statement_list (stmt::accum) next
	      end
	    end
          | V.CJmp(test, V.Name(true_lab), V.Name(false_lab)) ->
	    begin
	      match (decode_eip true_lab), (decode_eip false_lab) with
	      | X86eip tval, X86eip fval ->
		[ Instruction {eip = tval;
			       vine_stmts = V.ExpStmt test :: accum};
		  (* this not is bitwise -- might be wrong JTT *)
		Instruction {eip = fval;
			     vine_stmts = V.ExpStmt (V.UnOp (V.NOT, test)) :: accum}]
	      | X86eip tval, Internal fval ->
		(Instruction {eip = tval;
			      vine_stmts = V.ExpStmt test :: accum}) ::
		  (match walk_to_label false_lab tl with
		  | None -> [InternalLoop i1.eip]
		  | Some next -> walk_statement_list (stmt::accum) next)
	      | Internal tval, X86eip fval ->
		(Instruction {eip = fval;
			      vine_stmts = V.ExpStmt (V.UnOp (V.NOT, test)) :: accum}) ::
		  (match walk_to_label true_lab tl with
		  | None -> [InternalLoop i1.eip]
		  | Some next -> walk_statement_list (stmt::accum) next)
	      | Internal tval, Internal fval ->
		begin
		  let next = walk_statement_list (stmt::accum) in
		  match (walk_to_label true_lab tl), (walk_to_label false_lab tl) with
		  | None, None -> [InternalLoop i1.eip; InternalLoop i1.eip;]
		  | Some rem, None
		  | None, Some rem -> InternalLoop i1.eip :: (next rem)
		  | Some r1, Some r2 -> List.rev_append (next r1) (next r2)
		end
	    end
	  | V.Special("int 0x80") -> [SysCall {eip = Int64.add i1.eip Int64.one;
					       vine_stmts = accum; }]
	  | V.Return _ -> [Return i1.eip]
	  | V.Call _ -> [FunCall i1.eip]
	  | V.Halt _  -> [Halt i1.eip]
	  | _ -> walk_statement_list (stmt::accum) tl
	end in
      walk_statement_list [] statement_list


let rec exp_of_stmt = function
  | V.Jmp exp 
  | V.ExpStmt exp 
  | V.Assert exp
  | V.Halt exp -> Some exp
  | V.Label label -> Some (V.Name label)
  | V.Special string -> None (* failwith "Don't know what to do with magic" *)
  | V.Move (lvalue, exp) -> None (* failwith "punt for later" (** equation rewriting *) *)
  | V.Comment string -> None
  | V.Block (decls, stmts) -> None (* failwith "punt for later" *)
  | V.Attr (stmt, _) -> exp_of_stmt stmt
  | _ -> assert false


let stmts_of_data = function
  | SysCall pointer_statements
  | Instruction pointer_statements -> pointer_statements.vine_stmts
  | InternalLoop _
  | Return _
  | Halt _
  | FunCall _
  | BreakLoop _ -> []


(*

  Just a couple of notes on the translation:

  It will likely be faster if we go bottom up (that is, exits first).
  Common subexpression caching works best with that direction of an
  approach.  It's akin to dynamic programming.

  For truly big regions, we could blow the stack here.  Rewriting the code with a
  heap based stack insted of the stack being the call stack should be easy enough.

  There's probably a better way to approach this than 4 mutually recursive functions,
  but I can't find it.

*)
    
let build_equations ?context:(context = []) (root : node) =
  let cached_statments = Hashtbl.create 50
  and common_expressions = Hashtbl.create 50 in
  let rec be_int context node =
    let id = (key node) in
    try
      Hashtbl.find common_expressions id
    with Not_found ->
      match node.children with
      | [] -> 
	begin 
	  let to_add = VOpt.simplify (walk_statement_list id node) in
	  Hashtbl.add common_expressions id to_add;
	  to_add
	end
      | [singleton] ->
	begin
	  let to_add = VOpt.simplify (V.BinOp (V.BITAND,
					       walk_statement_list id node, 
					       be_int context singleton)) in
	  Hashtbl.add common_expressions id to_add;
	  to_add
	end
      | head::tail ->
	begin
	  let to_add = VOpt.simplify (V.BinOp (V.BITAND, 
					       walk_statement_list id node,
					       walk_child_list node.children)) in
	  Hashtbl.add common_expressions id to_add;
	  to_add
	end
  and walk_statement_list id node =
    try
      Hashtbl.find cached_statments id
    with Not_found ->
      let to_add = VOpt.simplify (wsl_int (stmts_of_data node.data)) in
      Hashtbl.add cached_statments id to_add;
      to_add
  and wsl_int = function 
    | [] ->  V.exp_true
    | head::tail ->
      begin
        match exp_of_stmt head with
          | None -> wsl_int tail
          | Some exp ->  V.BinOp (V.BITAND, exp, wsl_int tail)
      end 
  and walk_child_list = function
    | [one] -> be_int context one
    | [one; two] -> V.BinOp (V.BITOR,
			     be_int context one,
			     be_int context two)
    | _ -> failwith "assert 0 < |child_list| < 3 failed" in
  be_int context root

