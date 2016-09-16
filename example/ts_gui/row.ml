open! Core_kernel.Std
open! Incr_dom.Std
open! Incr.Let_syntax

module Model = struct
  type t =
    { symbol    : string
    ; edge      : float
    ; max_edge  : float
    ; trader    : string
    ; bsize     : int
    ; bid       : float
    ; ask       : float
    ; asize     : int
    ; position  : int
    ; last_fill : Time.t
    }
  [@@deriving compare, fields]

  let columns =
    let append f list field = f field :: list in
    let add ?(editable=false) ?focus_on_edit ?sort_by  m =
      append (fun field -> Column.of_field field m ~editable ?sort_by ?focus_on_edit)
    in
    let num_f x = Sort_key.Float x in
    let num_i x ~f = Sort_key.Float (Float.of_int (f x)) in
    let num_i = num_i ~f:Fn.id in
    let time t =
      Sort_key.Float (Float.of_int64 @@ Int63.to_int64
                      @@ Time.to_int63_ns_since_epoch t)
    in
    let lex_s x = Sort_key.String x in
    Fields.fold ~init:[]
      ~symbol:   (add (module String) ~sort_by:lex_s)
      ~edge:     (add (module Float) ~editable:true ~focus_on_edit:() ~sort_by:num_f)
      ~max_edge: (add (module Float) ~editable:true ~sort_by:num_f)
      ~trader:   (add (module String) ~editable:true ~sort_by:lex_s)
      ~bsize:    (add (module Int) ~sort_by:num_i)
      ~bid:      (add (module Float) ~sort_by:num_f)
      ~ask:      (add (module Float) ~sort_by:num_f)
      ~asize:    (add (module Int) ~sort_by:num_i)
      ~position: (add (module Int) ~sort_by:num_i)
      ~last_fill: (add (module Time) ~sort_by:time)
    |> List.rev

  let matches_pattern t pattern =
    let matches s =
      String.is_substring ~substring:pattern
        (String.lowercase s)
    in
    matches t.symbol || matches t.trader

  let apply_edit t ~column value =
    match List.find columns ~f:(fun col -> Column.name col = column) with
    | None -> t
    | Some column ->
      match Column.set column t value with
      | Error _ -> t
      | Ok t' -> t'

end

module Action = struct
  type t =
    | Kick_price
    | Kick_fill_time
  [@@deriving sexp]

  let kick_price = Kick_price
  let kick_fill_time = Kick_fill_time
end

let kick_price (m:Model.t) =
  let move = Float.of_int (Random.int 5 - 2) /. 100. in
  let spread = m.ask -. m.bid in
  let bid = Float.max 10. (m.bid +. move) in
  let ask = bid +. spread in
  { m with bid; ask }

let kick_fill_time (m:Model.t) =
  let position =
    let op = if (Random.bool ()) then Int.(+) else Int.(-) in
    op m.position (Random.int 200)
  in
  { m with position; last_fill = Time.now () }

let apply_action (action : Action.t) (m:Model.t) =
  match action with
  | Kick_price     -> kick_price m
  | Kick_fill_time -> kick_fill_time m

module Mode = struct
  type t = Unfocused | Focused | Editing
  [@@deriving sexp]
end

let editable_cell m col ~remember_edit =
  let open Vdom in
  let attrs =
    [ Attr.style [ "width", "100%" ]
    ; Attr.create "size" "1"
    ; Attr.value (Column.get col m)
    ; Attr.on_input (fun _ value ->
        remember_edit ~column:(Column.name col) value)
    ]
    @ (if Column.focus_on_edit col
       then [ Attr.id "focus-on-edit" ]
       else [])
  in
  Node.input attrs []
;;

let column_cell m col ~editing ~remember_edit =
  let open Vdom in
  if editing && Column.editable col
  then (editable_cell m col ~remember_edit)
  else (Node.span [] [Node.text (Column.get col m)])
;;

let view
      (m:Model.t Incr.t)
      ~row_id
      ~(mode: Mode.t Incr.t)
      ~sort_column
      ~focus_me
      ~remember_edit
  =
  let open Vdom in
  let on_click = Attr.on_click (fun _ -> focus_me) in
  let style =
    let%bind last_fill = m >>| Model.last_fill in
    let start_fading = Time_ns.add last_fill (Time_ns.Span.of_sec 1.0) in
    let end_fading   = Time_ns.add start_fading (Time_ns.Span.of_sec 1.0) in
    Incr.step_function ~init:(Some "new")
      [ start_fading, Some "fading"
      ; end_fading, None
      ]
  in
  let%map m = m and mode = mode and style = style in
  let focused_attr =
    match mode with
    | Focused | Editing -> [Attr.class_ "row-focused"]
    | Unfocused -> []
  in
  let editing =
    match mode with
    | Editing -> true
    | Focused | Unfocused -> false
  in
  let key = "row-" ^ row_id in
  Node.tr ~key
    (Attr.id key :: on_click :: focused_attr)
    (List.map Model.columns
       ~f:(fun col ->
         let attrs =
           let highlighting =
             if String.(=) (Column.name col) "position"
             then (Option.map style ~f:(fun x -> Attr.class_ x) |> Option.to_list)
             else []
           in
           if [%compare.equal:string option] (Some (Column.name col)) sort_column
           then begin
             match mode with
             | Focused | Editing -> highlighting
             | Unfocused -> ((Attr.class_ "sort-column") :: highlighting)
           end
           else highlighting
         in
         Node.td attrs [column_cell ~editing ~remember_edit m col]))

let random_stock () : Model.t =
  let symbol =
    let rchar () = Char.to_int 'A' + Random.int 26 |> Char.of_int_exn in
    String.init 4 ~f:(fun (_:int) -> rchar ())
  in
  let fair = 10. +. Float.of_int (Random.int 10000) /. 100. in
  let bsize = (1 + Random.int 20) * 100 in
  let asize = Int.max 100 (bsize + 100 * (Random.int 5 - 2)) in
  let bid = fair -. Float.of_int (Random.int 20) /. 100. in
  let ask = fair +. Float.of_int (Random.int 20) /. 100. in
  let edge = Float.of_int (Random.int 10) /. 100. in
  let max_edge = edge +. Float.of_int (Random.int 10) /. 100. in
  let position = Random.int 500 * 100 in
  let last_fill = Time.now () in
  let trader =
    let names = ["hsimmons"; "bkent"; "qhayes"; "gfernandez"] in
    List.nth_exn names (Random.int (List.length names))
  in
  { symbol; edge; max_edge; trader; bsize; asize; bid; ask; position; last_fill }

let random_rows n =
  List.init n ~f:(fun _ -> random_stock ())