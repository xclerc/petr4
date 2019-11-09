module I = Info
open Value
open Env
open Types
open Core
module Info = I


let assert_package (v : value) : Declaration.t * (string * value) list =
  match v with 
  | VPackage (obj,vs) -> (obj, vs) 
  | _ -> failwith "main is not a package" 

let assert_packet_in (p : vruntime) : packet_in =
  match p with
  | PacketIn x -> x
  | _ -> failwith "not a packet in"  

let assert_runtime (v : value) : vruntime =
  match v with
  | VRuntime r -> r
  | _ -> failwith "not a runtime value"

let init_val_of_typ _ _ _ = failwith "copy"

module type target = sig 
  type extern = EvalEnv.t -> value list -> EvalEnv.t * value

  val externs : (string * extern) list

  val check_pipeline : EvalEnv.t -> unit (* TODO: maybe something a bit more involved *)

  val eval_pipeline : EvalEnv.t -> packet_in -> 
  (EvalEnv.t -> signal -> value -> Argument.t list -> EvalEnv.t * signal * 'a) -> 
  (EvalEnv.t -> lvalue -> value -> EvalEnv.t * 'b) -> packet_in

end

module Core : target = struct 
  type extern = EvalEnv.t -> value list -> EvalEnv.t * value

  let externs = []

  let check_pipeline _ = failwith "core has no pipeline"

  let eval_pipeline _ _ = failwith "core has no pipeline"

end 

module V1Model : target = struct 
  type extern = EvalEnv.t -> value list -> EvalEnv.t * value

  let externs = []

  let check_pipeline env = ()

  let eval_v1control (app : 'a) (control : value) (args : Argument.t list)
      (env : EvalEnv.t) : EvalEnv.t * signal =
    let (env,s,_) = app env SContinue control args in
    (env,s)

  let eval_pipeline env pack app assign =
    let main = EvalEnv.find_val "main" env in
    let vs = assert_package main |> snd in
    let parser =
      List.Assoc.find_exn vs "p"   ~equal:(=) in
    let verify =
      List.Assoc.find_exn vs "vr"  ~equal:(=) in
    let ingress =
      List.Assoc.find_exn vs "ig"  ~equal:(=) in
    let egress =
      List.Assoc.find_exn vs "eg"  ~equal:(=) in
    let compute =
      List.Assoc.find_exn vs "ck"  ~equal:(=) in
    let deparser =
      List.Assoc.find_exn vs "dep" ~equal:(=) in
    let params =
      match parser with
      | VParser {pparams=ps;_} -> ps
      | _ -> failwith "parser is not a parser object" in
    let pckt = VRuntime (PacketIn pack) in
    let hdr =
      init_val_of_typ env "hdr"      (snd (List.nth_exn params 1)).typ in
    let meta =
      init_val_of_typ env "meta"     (snd (List.nth_exn params 2)).typ in
    let std_meta =
      init_val_of_typ env "std_meta" (snd (List.nth_exn params 3)).typ in
    let env =
      EvalEnv.(env
              |> insert_val "packet"   pckt
              |> insert_val "hdr"      hdr
              |> insert_val "meta"     meta
              |> insert_val "std_meta" std_meta
              |> insert_typ "packet"   (snd (List.nth_exn params 0)).typ
              |> insert_typ "hdr"      (snd (List.nth_exn params 1)).typ
              |> insert_typ "meta"     (snd (List.nth_exn params 2)).typ
              |> insert_typ "std_meta" (snd (List.nth_exn params 3)).typ) in
    (* TODO: implement a more responsible way to generate variable names *)
    let pckt_expr =
      (Info.dummy, Argument.Expression {value = (Info.dummy, Name (Info.dummy, "packet"))}) in
    let hdr_expr =
      (Info.dummy, Argument.Expression {value = (Info.dummy, Name (Info.dummy, "hdr"))}) in
    let meta_expr =
      (Info.dummy, Argument.Expression {value = (Info.dummy, Name (Info.dummy, "meta"))}) in
    let std_meta_expr =
      (Info.dummy, Argument.Expression {value = (Info.dummy, Name (Info.dummy, "std_meta"))}) in
    let (env, state, _) =
      app env SContinue parser [pckt_expr; hdr_expr; meta_expr; std_meta_expr] in
    let err = EvalEnv.get_error env in
    let env = if state = SReject
      then
        assign env (LMember(LName("std_meta"),"parser_error")) (VError(err)) |> fst
      else env in
    let pckt' =
      VRuntime (PacketOut(Cstruct.create 0, EvalEnv.find_val "packet" env
                                            |> assert_runtime
                                            |> assert_packet_in)) in
    let env = EvalEnv.insert_val "packet" pckt' env in
    let (env, _) = env
              |> eval_v1control app verify   [hdr_expr; meta_expr] |> fst
              |> eval_v1control app ingress  [hdr_expr; meta_expr; std_meta_expr] |> fst
              |> eval_v1control app egress   [hdr_expr; meta_expr; std_meta_expr] |> fst
              |> eval_v1control app compute  [hdr_expr; meta_expr] |> fst
              |> eval_v1control app deparser [pckt_expr; hdr_expr] in
    print_endline "After runtime evaluation";
    EvalEnv.print_env env;
    match EvalEnv.find_val "packet" env with
    | VRuntime (PacketOut(p0,p1)) -> Cstruct.append p0 p1
    | _ -> failwith "pack not a packet"

end
