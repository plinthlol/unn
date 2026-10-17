# the one terminal: colors, the zoom keys, clear, and the state around it
wait 400
type printf 'a\033[31mb\033[0mc\n'
key Return
wait 400
print-term
print-state
key ctrl+l
wait 200
print-term
cmd zoom_in
print-term-cell 0 0
quit
