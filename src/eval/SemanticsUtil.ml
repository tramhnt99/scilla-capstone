(* Utility function for creating strings for collecting semantics *)
open Core_kernel
open Scilla_base
open Identifier
open ParserUtil
open Syntax
open EvalUtil
open MonadUtil
open PatternMatching
open Stdint
open ContractUtil
open EvalTypeUtilities
open EvalIdentifier
open EvalType
open EvalLiteral
open EvalSyntax
open SemanticsUtil
open TypeChecker
module CU = ScillaContractUtil (ParserRep) (ParserRep)

let init_log = ([],[])

(* Option type to string *)
let opt_ty_to_string (ty:SType.t option) = 
    match ty with
    | Some ty' -> SType.pp_typ ty' 
    | None -> "___"


(* Collapse closures *)
let list_collapse (f_l:  ((String.t * SType.t option) * (String.t * SType.t option)) list) =
    let rec helper f_l' acc =
        match f_l' with
        | [] -> List.rev acc 
        | [h] -> List.rev (h :: acc)
        | h1 :: h2 :: t -> 
            begin
                if String.equal (fst @@ fst h1) "Lit <closure>" then
                    helper t @@ (fst h2, snd h1) :: acc 
                else helper (h2 :: t) @@ (h1) :: acc 
            end
    in
    helper f_l []


(* Build dictionary of variables and their inferred types *)
(* Also builds flow of variables into another *)
(* TODO: Infer type from the definition with the LOWER location *)
(* NOTE: we are NOT handling variables being redefined 
    - CAN BE DONE USING Hashtble's add Duplicate type 
    - not implemented right now
*)
let build_type_dict (f_l:  ((String.t * SType.t option) * (String.t * SType.t option)) list) =
    let dict: (String.t, SType.t) Hashtbl.t = Hashtbl.create (module String) in
    (* Infer types *)
    let rec infer_types prev_f v =
        match List.find prev_f ~f:(fun x -> String.equal (fst @@ fst x) v) with
        | None -> ()
        | Some (v1, v2) -> 
            print_string (sprintf "Building type for %s \n" (fst v1));
            let dict_value_v2 = 
                if Option.is_some (snd v1) then snd v1 else
                if Option.is_some @@ Hashtbl.find dict (fst v2) 
                then Hashtbl.find dict (fst v2) else 
                if Option.is_some (snd v2) then snd v2 else None
            in
            if Option.is_some dict_value_v2 then
                print_string (sprintf "Added type %s for %s \n" (opt_ty_to_string dict_value_v2) (fst v1));
                (Hashtbl.update dict (fst v1) 
                ~f:(fun x -> if Option.is_none x
                            then Option.value_exn dict_value_v2 else Option.value_exn x));
            (*Note: Don't call recursively because prev_f would contain assignments in order*)
    in
    List.iter f_l (fun ((x,y), _) -> infer_types f_l x);


    (* Creates a list of all values flown into it *)
    let rec trace_flow (prev_f:  ((String.t * SType.t option) * (String.t * SType.t option)) list) 
            v acc: (String.t * SType.t option) list =
        match List.find prev_f ~f:(fun x -> String.equal (fst @@ fst x) v) with
        | None -> List.rev acc 
        | Some (v1, v2) -> 
            (* If v2 has a type, ie. only a Literal *)
            if Option.is_some @@ snd v2 then List.rev (v2::acc)
            else
            trace_flow prev_f (fst v2) ((fst v2, Hashtbl.find dict (fst v2))::acc)
    in 
    let s_l = List.map f_l ~f:(fun ((x1, ty2), v2) -> 
        let trace = trace_flow f_l x1 [] in

        (*Type Checking - making sure everything flown into a variable is of the same type as variable's
        inferred type *)
        let ty_x = Hashtbl.find dict x1 in
        let type_check = 
            List.fold_left ~init:true trace ~f:(fun bool (x, ty) -> 
            if Option.is_some ty && Option.is_some ty_x then
             bool && SType.equal (Option.value_exn ty) (Option.value_exn ty_x)
            else bool)
        in
        let s = String.concat ~sep:" <- " (List.map trace ~f:(fun (x,y) -> sprintf "(%s: %s)" x (opt_ty_to_string y))) in
        let type_checked = if type_check then "=> Flows type check" else "=> Flow does not type check" in
        sprintf "%s: %s <- (%s) %s" x1 (opt_ty_to_string (Hashtbl.find dict x1)) s type_checked
    )
    in
    let dict_l = List.map (Hashtbl.to_alist dict) ~f:(fun (x, y) -> sprintf "(%s: %s)" x (SType.pp_typ y)) in 
    String.concat ~sep:"\n" 
        (List.filter s_l ~f:(fun s -> not @@ String.equal s "Variable t: ___ <- ((TAppIntUtils.int_neq: ___))")), 
    String.concat ~sep:" ;" dict_l


(* Used in eval_runner to print output *)
let output_seman log_l =
    (* Filter built-in flows *)
    let filtered_flow = List.filteri (fst log_l) ~f:(fun i _ -> i > 571) in

    (* Collapse closure flows *)
    let collapsed_flow = list_collapse filtered_flow in

    (* Filter log from empty logs *)
    let filtered_log = List.filter (snd log_l) ~f:(fun s -> not (String.equal s "")) in 

    (* Build type dictionary and flows *)
    let flow, dict = build_type_dict collapsed_flow in
    let pre_edit = List.map collapsed_flow ~f:(fun ((x1, y1),(x2, y2)) -> 
        sprintf "(%s, %s),(%s, %s)" x1 (opt_ty_to_string y1) x2 (opt_ty_to_string y2)) 
            |> String.concat ~sep:"\n"
    in
    "\nLogging sequence: \n" ^
    (String.concat ~sep:"\n" filtered_log) ^ 
    "\n\nPre-Edited Flow: \n" ^ pre_edit ^
    "\n\nFlows: \n" ^ flow ^ "\n" ^
    "\n\nDict: \n" ^ dict ^ "\n" 

let to_string = SIdentifier.as_string

(* open TypeChecker
open TypeUtil *)

(* Makes all Literals into strings other than GasExpr *)
let rec no_gas_to_string l =
    (* let tenv = TEnv.mk () in
    let typed_expr = TypeChecker.type_expr l tenv TypeChecker.init_gas_kont (Uint64.of_int 0) in *)
    match l with 
        | Literal l -> "Lit " ^ (Env.pp_value l)
        | Var i -> "Variable " ^ SIdentifier.as_string i
        | Let (i1, _, i2, _)  -> "Let " ^ to_string i1 ^ " = " ^ (no_gas_to_string @@ fst i2) (*Because we get Gas next*)
        | Message _ -> "Message"
        | Fun (i, ty, _) -> sprintf "Fun (Var %s: %s)" (to_string i) (SType.pp_typ ty)
        | App (i, i_l) -> "App " ^ to_string i ^ " --to--> (" ^ (String.concat ~sep:", " (List.map ~f:(fun x -> to_string x) i_l)) ^ " )"   
        | Constr (i, _, _) -> "Constr " ^ to_string i
        | MatchExpr (i, _) -> "MatchExpr " ^ to_string i
        | Builtin _ -> "Builtin"
        | TFun (i, _) -> "TFun " ^ to_string i
        | TApp (i, _) -> "TApp" ^ to_string i
        | Fixpoint _ -> "Fixpoint"
        | GasExpr (_, e) -> no_gas_to_string (fst e)


(* **********************************************

Printing semantics

************************************************ *)
(*Printing a Let expr*)
let let_semantics i lhs lval =
    sprintf "Let: %s <- (%s) = (%s)" (to_string i) (no_gas_to_string @@ fst lhs) (Env.pp_value lval)

(* Printing Variable expr*)
let var_semantics i v = 
    sprintf "Variable: %s -> (%s)" (to_string i)(Env.pp_value v)

(* Printing Application expr - Pre-evaluation *)
let app_semantics_pre i i_l = 
    sprintf "App-Pre: %s -to-> (%s)" (to_string i) 
        (String.concat ~sep:", " (List.map ~f:(fun x -> to_string x) i_l))

(* Printing Application expr - Post-evaluation *)
let app_semantics_post i i_l lit = 
    sprintf "App-Post: %s -to-> (%s) = %s" (to_string i) 
        (String.concat ~sep:", " (List.map ~f:(fun x -> to_string x) i_l)) (no_gas_to_string lit)

(* Printing Fun expr *)
let fun_semantics i ty body =
    sprintf "Fun: Var %s: %s" (to_string i) (SType.pp_typ ty)

(* Closure application *)
let closure_seman var arg ty =
    sprintf "Closure App: Var %s: %s <- (%s)" (no_gas_to_string var) 
        (opt_ty_to_string ty) (no_gas_to_string arg)

(* Closure actual flow *)
let closure_act clo var arg =
    sprintf "Closure %s <- Var %s = Lit %s" (no_gas_to_string clo) 
        (no_gas_to_string var) (no_gas_to_string arg)

(* Printing Message *) 
let mes_semantics bs = 
    sprintf "Message: [%s]" @@
        String.concat ~sep: ", " (List.map bs (fun (x1, x2) -> x1))

let constr_semantics constr =
    sprintf "Const: %s" (no_gas_to_string constr)

let match_semantics x =
    sprintf "MatchExpr: %s" (to_string x)

let tfun_semantics tv body =
    sprintf "TFun: Var %s: (%s)" (to_string tv) (no_gas_to_string body)

let tapp_semantics tf arg_types =
    sprintf "TApp: %s --to--> (%s)" (to_string tf) (String.concat ~sep:", " (List.map ~f:(fun x -> SType.pp_typ x) arg_types))

(* module TC = TypeChecker.ScillaTypechecker (ParserRep) (ParserRep)
open TC.TypeEnv.TEnv
let new_flow v1 v2 (ty: SType.t option): ((String.t * LType.t option) * (String.t * LType.t option)) List.t =

    let tenv = TC.TypeEnv.TEnv.mk () in

    let v1' = (no_gas_to_string v1, ty) in
    let res = TC.type_expr v2 tenv TC.init_gas_kont (Uint64.of_int 0) in
    let v2_type: LType.t option = 
        match res with
        | Ok ((_, (v2_ty, _)), _) -> Some v2_ty (* Error: inferred_type <> LType *)
        | Error x -> None
    in
    [] *)

(*Remove expr from its Gas Wrapper - Assuming only 1 layer*)
let un_gas v = 
    match v with
    | GasExpr (_, e) -> fst e
    | _ -> v

(* Adding v2 flowed into v1. If v2 is a Literal expr, then record its type too*)
let new_flow v1 v2 (ty: SType.t option): ((String.t * LType.t option) * (String.t * LType.t option)) =
    let v1' = (no_gas_to_string v1, ty) in
    match un_gas v2 with
    | Literal l -> 
        begin
        match l with
        | Clo _ -> (v1', (no_gas_to_string v2, None))
        | _ ->
            match literal_type l with 
            | Ok ty' -> (v1', (no_gas_to_string v2, Some ty'))
            | Error _ -> (v1', (no_gas_to_string v2, None)) (*Closures don't have types*)
        end
    | Fun (i, typ, body) -> 
        (v1', (no_gas_to_string v2, Some typ))
    | _ -> (v1', (no_gas_to_string v2, None))

(*Multiple new_flow*)
let new_flows v1 v2_l ty : ((String.t * LType.t option) * (String.t * LType.t option)) List.t =
    List.map v2_l ~f:(fun v2 -> new_flow v1 v2 ty)

