(*
  This file is part of scilla.

  Copyright (c) 2018 - present Zilliqa Research Pvt. Ltd.
  
  scilla is free software: you can redistribute it and/or modify it under the
  terms of the GNU General Public License as published by the Free Software
  Foundation, either version 3 of the License, or (at your option) any later
  version.
 
  scilla is distributed in the hope that it will be useful, but WITHOUT ANY
  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
  A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
 
  You should have received a copy of the GNU General Public License along with
  scilla.  If not, see <http://www.gnu.org/licenses/>.
*)

open Core_kernel
open Scilla_base
open Identifier
open ParserUtil
open Syntax
open ErrorUtils
open EvalUtil
open MonadUtil
open EvalMonad
open EvalMonad.Let_syntax
open PatternMatching
open Stdint
open ContractUtil
open PrettyPrinters
open EvalTypeUtilities
open EvalIdentifier
open EvalType
open EvalLiteral
open EvalSyntax
open SemanticsUtil
module CU = ScillaContractUtil (ParserRep) (ParserRep)

(***************************************************)
(*                    Utilities                    *)
(***************************************************)

let reserved_names =
  List.map
    ~f:(fun entry ->
      match entry with
      | LibVar (lname, _, _) -> get_id lname
      | LibTyp (tname, _) -> get_id tname)
    RecursionPrinciples.recursion_principles

(* Printing result *)
let pp_result r exclude_names gas_remaining =
  let enames = List.append exclude_names reserved_names in
  match r with
  | Error (s, _, _) -> sprint_scilla_error_list s
  | Ok ((e, env), _, _) ->
      let filter_prelude (k, _) =
        not @@ List.mem enames k ~equal:[%equal: EvalName.t]
      in
      sprintf "%s,\n%s\nGas remaining: %s" (Env.pp_value e)
        (Env.pp ~f:filter_prelude env)
        (Stdint.Uint64.to_string gas_remaining)

(* Makes sure that the literal has no closures in it *)
(* TODO: Augment with deep checking *)
let rec is_pure_literal l =
  match l with
  | Clo _ -> false
  | TAbs _ -> false
  | Msg es -> List.for_all es ~f:(fun (_, l') -> is_pure_literal l')
  | ADTValue (_, _, es) -> List.for_all es ~f:(fun e -> is_pure_literal e)
  (* | Map (_, ht) ->
   *     let es = Caml.Hashtbl.to_alist ht in
   *     List.for_all es ~f:(fun (k, v) -> is_pure_literal k && is_pure_literal v) *)
  | _ -> true

(* Sanitize before storing into a message *)
let sanitize_literal l =
  let open MonadUtil in
  let open Result.Let_syntax in
  let%bind t = literal_type l in
  if is_serializable_type t then pure l
  else fail0 @@ sprintf "Cannot serialize literal %s" (pp_literal l)

let eval_gas_charge env g =
  let open MonadUtil in
  let open Result.Let_syntax in
  let open EvalGas.GasSyntax in
  let logger u = Float.to_int @@ Float.log (u +. 1.0) in
  let resolver = function
    | SGasCharge.SizeOf vstr ->
        let%bind l = Env.lookup env (mk_loc_id vstr) in
        EvalGas.literal_cost l
    | SGasCharge.ValueOf vstr -> (
        let%bind l = Env.lookup env (mk_loc_id vstr) in
        match l with
        | UintLit (Uint32L ui) -> pure @@ Uint32.to_int ui
        | _ ->
            fail0
              ( "Variable "
              ^ EvalName.as_error_string vstr
              ^ " did not resolve to an integer" ) )
    | SGasCharge.LogOf vstr -> (
        let%bind l = Env.lookup env (mk_loc_id vstr) in
        match l with
        | ByStrX s' when Bystrx.width s' = Scilla_crypto.Snark.scalar_len ->
            let s = Bytes.of_string @@ Bystrx.to_raw_bytes s' in
            let u = Integer256.Uint256.of_bytes_big_endian s 0 in
            pure @@ logger (Integer256.Uint256.to_float u)
        | UintLit (Uint32L i) -> pure (logger (Stdint.Uint32.to_float i))
        | UintLit (Uint64L i) -> pure (logger (Stdint.Uint64.to_float i))
        | UintLit (Uint128L i) -> pure (logger (Stdint.Uint128.to_float i))
        | UintLit (Uint256L i) -> pure (logger (Integer256.Uint256.to_float i))
        | _ -> fail0 "eval_gas_charge: Cannot take logarithm of value" )
    | SGasCharge.LengthOf vstr -> (
        let%bind l = Env.lookup env (mk_loc_id vstr) in
        match l with
        | Map (_, m) -> pure @@ Caml.Hashtbl.length m
        | ADTValue _ ->
            let%bind l' = Datatypes.scilla_list_to_ocaml l in
            pure @@ List.length l'
        | _ -> fail0 "eval_gas_charge: Can only take length of Maps and Lists" )
    | SGasCharge.MapSortCost vstr ->
        let%bind m = Env.lookup env (mk_loc_id vstr) in
        pure @@ EvalGas.map_sort_cost m
    | SGasCharge.SumOf _ | SGasCharge.ProdOf _ | SGasCharge.DivCeil _
    | SGasCharge.MinOf _ | SGasCharge.StaticCost _ ->
        fail0 "eval_gas_charge: Must be handled by GasCharge"
  in
  SGasCharge.eval resolver g

let builtin_cost env f tps args_id =
  let open MonadUtil in
  let open Result.Let_syntax in
  let%bind cost_expr = EvalGas.builtin_cost f tps args_id in
  let%bind cost = eval_gas_charge env cost_expr in
  pure cost

(* Return a builtin_op wrapped in EvalMonad *)
let builtin_executor env f args_id =
  let%bind arg_lits =
    mapM args_id ~f:(fun arg -> fromR @@ Env.lookup env arg)
  in
  let%bind tps = fromR @@ MonadUtil.mapM arg_lits ~f:literal_type in
  let%bind _, ret_typ, op =
    fromR @@ EvalBuiltIns.BuiltInDictionary.find_builtin_op f tps
  in
  let%bind cost = fromR @@ builtin_cost env f tps args_id in
  let res () = op arg_lits ret_typ in
  checkwrap_opR res (Uint64.of_int cost)



(*******************************************************)
(* A monadic big-step evaluator for Scilla expressions *)
(*******************************************************)

(* [Evaluation in CPS]

   The following evaluator is implemented in a monadic style, with the
   monad, at the moment to be CPS, with the specialised return result
   type as described in [Specialising the Return Type of Closures].
 *)

let rec exp_eval erep env =
  let e, loc = erep in
  match e with
  | Literal l -> collecting_semantics (fun () -> pure (l, env)) loc ([], no_gas_to_string e)
  | Var i ->
      let%bind v = fromR @@ Env.lookup env i in
      let thunk () = pure (v, env) in
      collecting_semantics thunk loc ([], var_semantics i v)
  | Let (i, ty, lhs, rhs) ->
      let%bind lval, _ = exp_eval lhs env in
      let env' = Env.bind env (get_id i) lval in
      let thunk () = exp_eval rhs env' in
      collecting_semantics thunk loc ([new_flow (Var i) (fst lhs) ty],(let_semantics i lhs lval))
  | Message bs ->
      (* Resolve all message payload *)
      let resolve pld =
        match pld with
        | MLit l -> sanitize_literal l
        | MVar i ->
            let open Result.Let_syntax in
            let%bind v = Env.lookup env i in
            sanitize_literal v
      in
      let%bind payload_resolved =
        (* Make sure we resolve all the payload *)
        mapM bs ~f:(fun (s, pld) -> liftPair2 s @@ fromR @@ resolve pld)
      in
      let thunk () = pure (Msg payload_resolved, env) in
      collecting_semantics thunk loc ([], mes_semantics bs)
  | Fun (formal, ty, body) ->
      (* Apply to an argument *)
      let runner arg =
        let env1 = Env.bind env (get_id formal) arg in
        let thunk2 () = exp_eval body env1 in
        fstM @@ collecting_semantics thunk2 loc 
          ([new_flow (Var formal) (Literal arg) (Some ty)], closure_seman (Var formal) (Literal arg) (Some ty))
      in
      let thunk () = pure (Clo runner, env) in 
      collecting_semantics thunk loc ([], fun_semantics formal ty (fst body))
  | App (f, actuals) ->
      (*Record that App is being evaluated before evaluating the rest*)
      let thunk () =
        (* Resolve the actuals *)
        (* let%bind args =
          mapM actuals ~f:(fun arg -> fromR @@ Env.lookup env arg)
        in
        let%bind ff = fromR @@ Env.lookup env f in
        (* Apply iteratively, also evaluating curried lambdas *)
        let%bind fully_applied =
          List.fold_left args ~init:(pure ff) ~f:(fun res arg ->
              let%bind v = res in
              try_apply_as_closure v arg)
        in *)
        let%bind ff = fromR @@ Env.lookup env f in
        let%bind fully_applied =
          List.fold_left actuals ~init:(pure ff) ~f:(fun res actual ->
              let%bind arg = fromR @@ Env.lookup env actual in
              let%bind v = res in
              let thunk3 () = liftPair1 (try_apply_as_closure v arg) env in
              fstM @@ 
              collecting_semantics thunk3 loc ([new_flow (Literal v) (Var actual) None], 
                closure_act (Literal v) (Var actual) (Literal arg))
          )
        in
        let thunk2 () = pure (fully_applied, env) in
        collecting_semantics thunk2 loc ([], app_semantics_post f actuals (Literal fully_applied))
      in
      let actuals_var = List.map actuals ~f:(fun act -> Var act) in
      collecting_semantics thunk loc (new_flows (Var f) actuals_var None, app_semantics_pre f actuals)
  | Constr (cname, ts, actuals) ->
      let open Datatypes.DataTypeDictionary in
      let%bind _, constr =
        fromR
        @@ lookup_constructor ~sloc:(SR.get_loc (get_rep cname)) (get_id cname)
      in
      let alen = List.length actuals in
      if constr.arity <> alen then
        fail1_log
          (sprintf "Constructor %s expects %d arguments, but got %d."
             (as_error_string cname) constr.arity alen)
          (SR.get_loc (get_rep cname))
      else
        (* Resolve the actuals *)
        let%bind args =
          mapM actuals ~f:(fun arg -> fromR @@ Env.lookup env arg)
        in
        (* Make sure we only pass "pure" literals, not closures *)
        let lit = ADTValue (get_id cname, ts, args) in
        let thunk () = pure (lit, env) in
        collecting_semantics thunk loc ([], constr_semantics e)
  | MatchExpr (x, clauses) ->
      let%bind v = fromR @@ Env.lookup env x in
      (* Get the branch and the bindings *)
      let%bind (_, e_branch), bnds =
        tryM clauses
          ~msg:(fun () ->
            mk_error1
              (sprintf "Match expression failed. No clause matched.")
              loc)
          ~f:(fun (p, _) -> fromR @@ match_with_pattern v p)
      in
      (* Update the environment for the branch *)
      let env' =
        List.fold_left bnds ~init:env ~f:(fun z (i, w) ->
            Env.bind z (get_id i) w)
      in
      let thunk () = exp_eval e_branch env' in
      collecting_semantics thunk loc ([], match_semantics x)
  | Builtin (i, actuals) ->
      let%bind res = builtin_executor env i actuals in
      pure (res, env)
  | Fixpoint (g, _, body) ->
      let rec fix arg =
        let env1 = Env.bind env (get_id g) clo_fix in
        let%bind fbody, _ = exp_eval body env1 in
        match fbody with
        | Clo f -> f arg
        | _ -> fail0_log "Cannot apply fxpoint argument to a value"
      and clo_fix = Clo fix in
      pure (clo_fix, env)
  | TFun (tv, body) ->
      let typer arg_type =
        let body_subst = subst_type_in_expr tv arg_type body in
        fstM @@ exp_eval body_subst env
      in
      let thunk () = pure (TAbs typer, env) in
      collecting_semantics thunk loc ([], tfun_semantics tv @@ fst body)
  | TApp (tf, arg_types) ->
      let%bind ff = fromR @@ Env.lookup env tf in
      let%bind fully_applied =
        List.fold_left arg_types ~init:(pure ff) ~f:(fun res arg_type ->
            let%bind v = res in
            try_apply_as_type_closure v arg_type)
      in
      let thunk () = pure (fully_applied, env) in
      collecting_semantics thunk loc ([], tapp_semantics tf arg_types)
  | GasExpr (g, e') ->
      let thunk () = exp_eval e' env in
      let%bind cost = fromR @@ eval_gas_charge env g in
      let emsg = sprintf "Ran out of gas.\n" in
      (* Add end location too: https://github.com/Zilliqa/scilla/issues/134 *)
      checkwrap_op thunk (Uint64.of_int cost) (mk_error1 emsg loc)

(* Applying a function *)
and try_apply_as_closure v arg =
  match v with
  | Clo clo -> clo arg
  | _ -> fail0_log @@ sprintf "Not a functional value: %s." (Env.pp_value v)

and try_apply_as_type_closure v arg_type =
  match v with
  | TAbs tclo -> tclo arg_type
  | _ -> fail0_log @@ sprintf "Not a type closure: %s." (Env.pp_value v)

(* Collecting concrete semantics, current as Strings *)
and collecting_semantics thunk loc log =
  (* remove builtins *)
  let loc_log =
    if String.equal (String.sub ~pos:0 ~len:10 (get_loc_str loc)) "src/stdlib" 
        || String.equal (String.sub ~pos:0 ~len:7 (get_loc_str loc)) "Prelude" 
    then ""
    else 
    (* (get_loc_str loc) ^ " " ^  *)
    (snd log) 
  in
  let emsg = sprintf "Logging of variable failure. \n" in
  checkwrap_op_log thunk (Uint64.of_int 0) (mk_error1 emsg loc) (fst log, [loc_log])

(* [Initial Gas-Passing Continuation]

   The following function is used as an initial continuation to
   "bootstrap" the gas-aware computation and then retrieve not just
   the result, but also the remaining gas.

*)
let init_gas_kont r gas' log' =
  match r with Ok z -> Ok (z, gas', log') | Error msg -> Error (msg, gas', log')

(* [Continuation for Expression Evaluation]

   The following function implements an impedance matcher. Even though
   it takes a continuation `k` from the callee, it starts evaluating
   an expression `expr` in a "basic" continaution `init_gas_kont` (cf.
   [Initial Gas-Passing Continuation]) with a _fixed_ result type (cf
   [Specialising the Return Type of Closures]). In short, it fully
   evaluates an expression with the fixed continuation, after which
   the result is passed further to the callee's continuation `k`.

*)
let exp_eval_wrapper_no_cps expr env k gas log =
  let eval_res = exp_eval expr env init_gas_kont gas log in
  let res, remaining_gas, current_log =
    match eval_res with 
      |  Ok (z, g, l) ->
          (Ok z, g, l)
      | Error (m, g, l) ->
          (Error m, g, l)
  in
  k res remaining_gas current_log

open EvalSyntax

(*******************************************************)
(* A monadic big-step evaluator for Scilla statemnts   *)
(*******************************************************)
let rec stmt_eval conf stmts =
  match stmts with
  | [] -> pure conf
  | (s, sloc) :: sts -> (
      match s with
      | Load (x, r) ->
          let%bind l = Configuration.load conf r in
          let conf' = Configuration.bind conf (get_id x) l in
          stmt_eval conf' sts
      | Store (x, r) ->
          let%bind v = fromR @@ Configuration.lookup conf r in
          let%bind () = Configuration.store x v in
          stmt_eval conf sts
      | Bind (x, e) ->
          let%bind lval, _ = exp_eval_wrapper_no_cps e conf.env in
          let conf' = Configuration.bind conf (get_id x) lval in
          stmt_eval conf' sts
      | MapUpdate (m, klist, ropt) ->
          let%bind klist' =
            mapM ~f:(fun k -> fromR @@ Configuration.lookup conf k) klist
          in
          let%bind v =
            match ropt with
            | Some r ->
                let%bind v = fromR @@ Configuration.lookup conf r in
                pure (Some v)
            | None -> pure None
          in
          let%bind () = Configuration.map_update m klist' v in
          stmt_eval conf sts
      | MapGet (x, m, klist, fetchval) ->
          let%bind klist' =
            mapM ~f:(fun k -> fromR @@ Configuration.lookup conf k) klist
          in
          let%bind l = Configuration.map_get conf m klist' fetchval in
          let conf' = Configuration.bind conf (get_id x) l in
          stmt_eval conf' sts
      | ReadFromBC (x, bf) ->
          let%bind l = Configuration.bc_lookup conf bf in
          let conf' = Configuration.bind conf (get_id x) l in
          stmt_eval conf' sts
      | MatchStmt (x, clauses) ->
          let%bind v = fromR @@ Env.lookup conf.env x in
          let%bind (_, branch_stmts), bnds =
            tryM clauses
              ~msg:(fun () ->
                mk_error0
                  (sprintf "Value %s\ndoes not match any clause of\n%s."
                     (Env.pp_value v) (pp_stmt s)))
              ~f:(fun (p, _) -> fromR @@ match_with_pattern v p)
          in
          (* Update the environment for the branch *)
          let conf' =
            List.fold_left bnds ~init:conf ~f:(fun z (i, w) ->
                Configuration.bind z (get_id i) w)
          in
          let%bind conf'' = stmt_eval conf' branch_stmts in
          (* Restore initial immutable bindings *)
          let cont_conf = { conf'' with env = conf.env } in
          stmt_eval cont_conf sts
      | AcceptPayment ->
          let%bind conf' = Configuration.accept_incoming conf in
          stmt_eval conf' sts
      (* Caution emitting messages does not change balance immediately! *)
      | SendMsgs ms ->
          let%bind ms_resolved = fromR @@ Configuration.lookup conf ms in
          let%bind conf' = Configuration.send_messages conf ms_resolved in
          stmt_eval conf' sts
      | CreateEvnt params ->
          let%bind eparams_resolved =
            fromR @@ Configuration.lookup conf params
          in
          let%bind conf' = Configuration.create_event conf eparams_resolved in
          stmt_eval conf' sts
      | CallProc (p, actuals) ->
          (* Resolve the actuals *)
          let%bind args =
            mapM actuals ~f:(fun arg -> fromR @@ Env.lookup conf.env arg)
          in
          let%bind proc, p_rest = Configuration.lookup_procedure conf p in
          (* Apply procedure. No gas charged for the application *)
          let%bind conf' = try_apply_as_procedure conf proc p_rest args in
          stmt_eval conf' sts
      | Iterate (l, p) ->
          let%bind l_actual = fromR @@ Env.lookup conf.env l in
          let%bind l' = fromR @@ Datatypes.scilla_list_to_ocaml l_actual in
          let%bind proc, p_rest = Configuration.lookup_procedure conf p in
          let%bind conf' =
            foldM l' ~init:conf ~f:(fun confacc arg ->
                let%bind conf' =
                  try_apply_as_procedure confacc proc p_rest [ arg ]
                in
                pure conf')
          in
          stmt_eval conf' sts
      | Throw eopt ->
          let%bind estr =
            match eopt with
            | Some e ->
                let%bind e_resolved = fromR @@ Configuration.lookup conf e in
                pure @@ ": " ^ pp_literal e_resolved
            | None -> pure ""
          in
          let err = mk_error1 ("Exception thrown" ^ estr) sloc in
          let elist =
            List.map conf.component_stack ~f:(fun cname ->
                {
                  emsg = "Raised from " ^ as_error_string cname;
                  startl = ER.get_loc (get_rep cname);
                  endl = dummy_loc;
                })
          in
          fail_log (err @ elist)
      | GasStmt g ->
          let%bind cost = fromR @@ eval_gas_charge conf.env g in
          let err =
            mk_error1 "Ran out of gas after evaluating statement" sloc
          in
          let remaining_stmts () = stmt_eval conf sts in
          checkwrap_op_log remaining_stmts (Uint64.of_int cost) err ([], ["stmt_eval at GasStmt"]))

and try_apply_as_procedure conf proc proc_rest actuals =
  (* Create configuration for procedure call *)
  let sender = GlobalName.parse_simple_name MessagePayload.sender_label in
  let origin = GlobalName.parse_simple_name MessagePayload.origin_label in
  let amount = GlobalName.parse_simple_name MessagePayload.amount_label in
  let%bind sender_value =
    fromR @@ Configuration.lookup conf (mk_loc_id sender)
  in
  let%bind origin_value =
    fromR @@ Configuration.lookup conf (mk_loc_id origin)
  in
  let%bind amount_value =
    fromR @@ Configuration.lookup conf (mk_loc_id amount)
  in
  let%bind proc_conf =
    Configuration.bind_all
      { conf with env = conf.init_env; procedures = proc_rest }
      ( origin :: sender :: amount
      :: List.map proc.comp_params ~f:(fun id_typ -> get_id (fst id_typ)) )
      (origin_value :: sender_value :: amount_value :: actuals)
  in
  let%bind conf' = stmt_eval proc_conf proc.comp_body in
  (* Reset configuration *)
  pure
    {
      conf' with
      env = conf.env;
      procedures = conf.procedures;
      component_stack = proc.comp_name :: conf.component_stack;
    }

(*******************************************************)
(*          BlockchainState initialization             *)
(*******************************************************)

let check_blockchain_entries entries =
  let expected = [ (TypeUtil.blocknum_name, BNum "0") ] in
  (* every entry must be expected *)
  let c1 =
    List.for_all entries ~f:(fun (s, _) ->
        List.Assoc.mem expected s ~equal:String.( = ))
  in
  (* everything expected must be entered *)
  let c2 =
    List.for_all expected ~f:(fun (s, _) ->
        List.Assoc.mem entries s ~equal:String.( = ))
  in
  if c1 && c2 then pure entries
  else
    fail0_log
    @@ sprintf
         "Mismatch in input blockchain variables:\n\
          expected:\n\
          %s\n\
          provided:\n\
          %s\n"
         (pp_literal_map expected) (pp_literal_map entries)

(*******************************************************)
(*              Contract initialization                *)
(*******************************************************)

(* Evaluate constraint, and abort if false *)
let eval_constraint cconstraint env =
  let%bind contract_val, _ = exp_eval_wrapper_no_cps cconstraint env in
  match contract_val with
  | ADTValue (c, [], []) when Datatypes.is_true_ctr_name c -> pure ()
  | _ -> fail0_log (sprintf "Contract constraint violation.\n")

let init_lib_entries env libs =
  let init_lib_entry env id e =
    let%map v, _ = exp_eval_wrapper_no_cps e env in
    Env.bind env (get_id id) v
  in
  List.fold_left libs ~init:env ~f:(fun eres lentry ->
      match lentry with
      | LibTyp (tname, ctr_defs) ->
          let open Datatypes.DataTypeDictionary in
          let ctrs, tmaps =
            List.fold_right ctr_defs ~init:([], [])
              ~f:(fun ctr_def (tmp_ctrs, tmp_tmaps) ->
                let { cname; c_arg_types } = ctr_def in
                ( {
                    Datatypes.cname = get_id cname;
                    Datatypes.arity = List.length c_arg_types;
                  }
                  :: tmp_ctrs,
                  (get_id cname, c_arg_types) :: tmp_tmaps ))
          in
          let adt =
            {
              Datatypes.tname = get_id tname;
              Datatypes.tparams = [];
              Datatypes.tconstr = ctrs;
              Datatypes.tmap = tmaps;
            }
          in
          let _ = add_adt adt (get_rep tname) in
          eres
      | LibVar (lname, _, lexp) ->
          let%bind env = eres in
          init_lib_entry env lname lexp)

(* Initializing libraries of a contract *)
let init_libraries clibs elibs =
  DebugMessage.plog "Loading library types and functions.";
  let%bind rec_env =
    let%bind rlibs =
      mapM
        ~f:(Fn.compose fromR EvalGas.lib_entry_cost)
        RecursionPrinciples.recursion_principles
    in
    init_lib_entries (pure Env.empty) rlibs
  in
  let rec recurser libnl =
    if List.is_empty libnl then pure rec_env
    else
      (* Walk through library dependence tree. *)
      foldM libnl ~init:[] ~f:(fun acc_env libnode ->
          let dep_env = recurser libnode.deps in
          let entries = libnode.libn.lentries in
          let%bind env' = init_lib_entries dep_env entries in
          (* Remove dep_env from env'. We don't want transitive imports.
           * TODO: Add a utility function in Env for this. *)
          let env =
            Env.filter env' ~f:(fun name ->
                (* If "name" exists in "entries" or rec_env, retain it. *)
                List.exists entries ~f:(fun entry ->
                    match entry with
                    | LibTyp _ -> false (* Types are not part of Env. *)
                    | LibVar (i, _, _) -> [%equal: EvalName.t] (get_id i) name)
                || List.Assoc.mem rec_env name ~equal:[%equal: EvalName.t])
          in
          pure @@ Env.bind_all acc_env env)
  in
  let extlibs_env = recurser elibs in
  (* Finally walk the local library. *)
  match clibs with
  | Some l -> init_lib_entries extlibs_env l.lentries
  | None -> extlibs_env

(* Initialize fields in a constant environment *)
let init_fields env fs =
  (* Initialize a field in a constant environment *)
  let init_field fname _t fexp =
    let%bind v, _ = exp_eval_wrapper_no_cps fexp env in
    match v with
    | l when is_pure_literal l -> pure (fname, l)
    | _ ->
        fail0_log
        @@ sprintf "Closure cannot be stored in a field %s."
             (EvalName.as_error_string fname)
  in
  mapM fs ~f:(fun (i, t, e) -> init_field (get_id i) t e)

let init_contract clibs elibs cconstraint' cparams' cfields args' init_bal =
  (* All contracts take a few implicit parameters. *)
  let cparams = CU.append_implict_contract_params cparams' in
  (* Remove arguments that the evaluator doesn't (need to) deal with.
   * Validation of these init parameters is left to the blockchain. *)
  let args = CU.remove_noneval_args args' in
  (* Initialize libraries *)
  let%bind libenv = init_libraries clibs elibs in
  (* Is there an argument that is not a parameter? *)
  let%bind () =
    forallM
      ~f:(fun a ->
        let%bind atyp = fromR @@ literal_type (snd a) in
        let emsg () =
          mk_error0
            (sprintf "Parameter %s : %s is not specified in the contract.\n"
               (EvalName.as_error_string (fst a))
               (pp_typ atyp))
        in
        (* For each argument there should be a parameter *)
        let%bind _, mp =
          tryM
            ~f:(fun (ps, pt) ->
              let%bind at = fromR @@ literal_type (snd a) in
              if
                [%equal: EvalName.t] (get_id ps) (fst a)
                && [%equal: EvalType.t] pt at
              then pure ()
              else fail0_log "")
            cparams ~msg:emsg
        in
        pure mp)
      args
  in
  let%bind () =
    forallM
      ~f:(fun (p, _) ->
        (* For each parameter there should be exactly one argument. *)
        if
          List.count args ~f:(fun a -> [%equal: EvalName.t] (get_id p) (fst a))
          <> 1
        then
          fail0_log
            (sprintf "Parameter %s must occur exactly once in input.\n"
               (as_error_string p))
        else pure ())
      cparams
  in
  (* Fold params into already initialized libraries, possibly shadowing *)
  let env = Env.bind_all libenv args in
  (* Evaluate constraint, and abort if false *)
  let%bind () = eval_constraint cconstraint' env in
  let%bind field_values = init_fields env cfields in
  let fields = List.map cfields ~f:(fun (f, t, _) -> (get_id f, t)) in
  let balance = init_bal in
  let open ContractState in
  let cstate = { env; fields; balance } in
  pure (cstate, field_values)

(* Combine initialized state with infro from current state *)
let create_cur_state_fields initcstate curcstate =
  (* If there's a field in curcstate that isn't in initcstate,
     flag it as invalid input state *)
  let%bind () =
    forallM
      ~f:(fun (s, lc) ->
        let%bind t_lc = fromR @@ literal_type lc in
        let emsg () =
          mk_error0
            (sprintf "Field %s : %s not defined in the contract\n"
               (EvalName.as_error_string s)
               (pp_typ t_lc))
        in
        let%bind _, ex =
          tryM
            ~f:(fun (t, li) ->
              let%bind t1 = fromR @@ literal_type lc in
              let%bind t2 = fromR @@ literal_type li in
              if [%equal: EvalName.t] s t && [%equal: EvalType.t] t1 t2 then
                pure ()
              else fail0_log "")
            initcstate ~msg:emsg
        in
        pure ex)
      curcstate
  in
  (* Each entry name is unique *)
  let%bind () =
    forallM
      ~f:(fun (e, _) ->
        if
          List.count curcstate ~f:(fun (e', _) -> [%equal: EvalName.t] e e') > 1
        then
          fail0_log
            (sprintf "Field %s occurs more than once in input.\n"
               (EvalName.as_error_string e))
        else pure ())
      initcstate
  in
  (* Get only those fields from initcstate that are not in curcstate *)
  let filtered_init =
    List.filter initcstate ~f:(fun (s, _) ->
        not (List.Assoc.mem curcstate s ~equal:[%equal: EvalName.t]))
  in
  (* Combine filtered list and curcstate *)
  pure (filtered_init @ curcstate)

(* Initialize a module with given arguments and initial balance *)
let init_module md initargs curargs init_bal bstate elibs =
  let { libs; contr; _ } = md in
  let { cconstraint; cparams; cfields; _ } = contr in
  let%bind initcstate, field_vals =
    init_contract libs elibs cconstraint cparams cfields initargs init_bal
  in
  let%bind curfield_vals = create_cur_state_fields field_vals curargs in
  (* blockchain input provided is only validated and not used here. *)
  let%bind () = EvalMonad.ignore_m @@ check_blockchain_entries bstate in
  let cstate = { initcstate with fields = initcstate.fields } in
  pure (contr, cstate, curfield_vals)

(*******************************************************)
(*               Message processing                    *)
(*******************************************************)

(* Extract necessary bits from the message *)
let preprocess_message es =
  let%bind tag = fromR @@ MessagePayload.get_tag es in
  let%bind amount = fromR @@ MessagePayload.get_amount es in
  let other = MessagePayload.get_other_entries es in
  pure (tag, amount, other)

(* Retrieve transition based on the tag *)
let get_transition_and_procedures ctr tag =
  let rec procedure_and_transition_finder procs_acc cs =
    match cs with
    | [] ->
        (* Transition not found *)
        (procs_acc, None)
    | c :: c_rest -> (
        match c.comp_type with
        | CompProc ->
            (* Procedure is in scope - continue searching *)
            procedure_and_transition_finder (c :: procs_acc) c_rest
        | CompTrans when String.(tag = as_string c.comp_name) ->
            (* Transition found - return *)
            (procs_acc, Some c)
        | CompTrans ->
            (* Not the correct transition - ignore *)
            procedure_and_transition_finder procs_acc c_rest )
  in
  let procs, trans_opt = procedure_and_transition_finder [] ctr.ccomps in
  match trans_opt with
  | None -> fail0_log @@ sprintf "No contract transition for tag %s found." tag
  | Some t ->
      let params = t.comp_params in
      let body = t.comp_body in
      let name = t.comp_name in
      pure (procs, params, body, name)

(* Ensure match b/w transition defined params and passed arguments (entries) *)
let check_message_entries cparams_o entries =
  let tparams = CU.append_implict_comp_params cparams_o in
  (* There as an entry for each parameter *)
  let valid_entries =
    List.for_all tparams ~f:(fun (s, _) ->
        List.Assoc.mem entries (as_string s) ~equal:String.( = ))
  in
  (* There is a parameter for each entry *)
  let valid_params =
    List.for_all entries ~f:(fun (s, _) ->
        List.exists tparams ~f:(fun (i, _) -> String.(s = as_string i)))
  in
  (* Each entry name is unique *)
  let uniq_entries =
    not
    @@ List.contains_dup entries ~compare:(fun (s, _) (t, _) ->
           String.compare s t)
  in
  if not (valid_entries && uniq_entries && valid_params) then
    fail0_log
    @@ sprintf
         "Duplicate entries or mismatch b/w message entries:\n\
          %s\n\
          and expected transition parameters%s\n"
         (pp_literal_map entries) (pp_cparams tparams)
  else pure entries

(* Get the environment, incoming amount, procedures in scope, and body to execute*)
let prepare_for_message contr m =
  match m with
  | Msg entries ->
      let%bind tag, incoming_amount, other = preprocess_message entries in
      let%bind tprocedures, tparams, tbody, tname =
        get_transition_and_procedures contr tag
      in
      let%bind tenv = check_message_entries tparams other in
      pure (tenv, incoming_amount, tprocedures, tbody, tname)
  | _ -> fail0_log @@ sprintf "Not a message literal: %s." (pp_literal m)

(* Subtract the amounts to be transferred *)
let post_process_msgs cstate outs =
  (* Evey outgoing message should carry an "_amount" tag *)
  let%bind amounts =
    mapM outs ~f:(fun l ->
        match l with
        | Msg es -> fromR @@ MessagePayload.get_amount es
        | _ -> fail0_log @@ sprintf "Not a message literal: %s." (pp_literal l))
  in
  let open Uint128 in
  let to_be_transferred =
    List.fold_left amounts ~init:zero ~f:(fun z a -> add z a)
  in
  let open ContractState in
  if compare cstate.balance to_be_transferred < 0 then
    fail0_log
    @@ sprintf
         "The balance is too low (%s) to transfer all the funds in the \
          messages (%s)"
         (to_string cstate.balance)
         (to_string to_be_transferred)
  else
    let balance = sub cstate.balance to_be_transferred in
    pure { cstate with balance }

(* 
Handle message:
* contr : Syntax.contract - code of the contract (containing transitions and procedures)
* cstate : ContractState.t - current contract state
* bstate : (string * literal) list - blockchain state
* m : Syntax.literal - incoming message 
*)
let handle_message contr cstate bstate m =
  let%bind tenv, incoming_funds, procedures, stmts, tname =
    prepare_for_message contr m
  in
  let open ContractState in
  let { env; fields; balance } = cstate in
  (* Add all values to the contract environment *)
  let%bind actual_env =
    foldM tenv ~init:env ~f:(fun e (n, l) ->
        (* TODO, Issue #836: Message fields may contain periods, which shouldn't be allowed. *)
        match String.split n ~on:'.' with
        | [ simple_name ] ->
            pure @@ Env.bind e (GlobalName.parse_simple_name simple_name) l
        | _ -> fail0_log @@ sprintf "Illegal field %s in incoming message" n)
  in
  let open Configuration in
  (* Create configuration *)
  let conf =
    {
      init_env = actual_env;
      env = actual_env;
      fields;
      balance;
      accepted = false;
      blockchain_state = bstate;
      incoming_funds;
      procedures;
      component_stack = [ tname ];
      emitted = [];
      events = [];
    }
  in

  (* Finally, run the evaluator for statements *)
  let%bind conf' = stmt_eval conf stmts in
  let cstate' =
    { env = cstate.env; fields = conf'.fields; balance = conf'.balance }
  in
  let new_msgs = conf'.emitted in
  let new_events = conf'.events in
  (* Make sure that we aren't too generous and subract funds *)
  let%bind cstate'' = post_process_msgs cstate' new_msgs in

  (*Return new contract state, messages and events *)
  pure (cstate'', new_msgs, new_events, conf'.accepted)
