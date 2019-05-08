

var cells = {};

function append_result(key, result) {
    if (key in cells) {
        var cell = cells[key];
    } else {
        var cell = new_cell();
        cells[key] = cell;
    }
    var source = result["source"];
    if (source != null) {
        cell.source.innerHTML = source.val;
    }
    var output = result["output"];
    cell.output.innerHTML += output;
    var status = result["status"];
    if (status != null) {
        if ("complete" in status.val) {
            cell.cell.className = "complete-cell";
        } else if ("failed" in status.val) {
            cell.output.innerHTML = status.val["failed"];
            cell.cell.className = "err-cell";
        }
    }

    //     if ("unevaluated" in instr) {
//         var cell = add_node(body, "output-cell", "");
//         add_node(cell, "source", source);
//         add_node(cell, "result-unevaluated", "");
//     } else if ("result" in instr) {
//         var cell = add_node(body, "output-cell", "");
//         add_node(cell, "source", source);
//         result = instr["result"];
//         if ("text" in result) {
//             add_node(cell, "result-text", result["text"]);
//         } else if ("plot" in result) {
//             plot_div = add_node(cell, "plot-output", "");
//             Plotly.plot(plot_div, [result["plot"]]);
//         }
//     } else if ("error" in instr) {
//         var cell = add_node(body, "err-cell", "");
//         add_node(cell, "source", source);
//         add_node(cell, "result-text", instr["error"]);
//     } else if ("source_only" in instr) {
//         var cell = add_node(body, "decl-cell", "");
//         add_node(cell, "source", source);
//     }
//     return cell;

};

function new_cell() {
    var cell = add_node(null, "pending-cell");
    var source = add_node(cell, "source");
    var output = add_node(cell, "result-text");
    return {"cell" : cell, "source" : source, "output" : output }
}


function add_node(parent, classname) {
    var newnode = document.createElement("div");
    newnode.className = classname;
    if (parent != null) parent.appendChild(newnode);
    return newnode;
}

var source = new EventSource("/getnext");
source.onmessage = function(event) {
    var results = JSON.parse(event.data);
    console.log(results);
    var order    = results[0];
    var contents = results[1];
    console.log(results);
    for (var i = 0; i < contents.length; i++) {
        append_result(contents[i][0], contents[i][1]);
    }
    // TODO: keys may appear twice, but they'll only show up once (html doesn't
    // allow repeated nodes). We need to make copies and keep them in sync.
    if (order != null) {
        var body = document.getElementById("main-output");
        body.innerHTML = "";
        for (var i = 0; i < order.val.length; i++) {
            body.appendChild(cells[order.val[i]].cell);
        }
    }
};