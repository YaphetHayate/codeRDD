# fixture code-metrics bridge-n7r1 (work side) - n7-round R1 replica:
# touched function with a 4-level stitch chain; at the 5-depth caliber
# this must NOT be reported (zero-FP contrast for the depth threshold).
function Invoke-Promulgate {
    # work side: deferred stitching 4-level chain foreach x3 -> if
    foreach ($task in $tasks) {
        foreach ($nodeId in $ids) {
            foreach ($edge in $edges) {
                if ($edge.from -eq $nodeId) {
                    $stitched = $edge
                }
            }
        }
    }
}
