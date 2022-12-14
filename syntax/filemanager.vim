" The following lines must be the same as in plugin/filemanager.vim
let s:depthstr = '| '
let s:depthstrmarked = '|+'
let s:depthstryanked = '|-'
let s:depthstrmarknyanked = '|#'
let s:depthstrpat = '\%(|[ +-\#]\)'
let s:depthstronlypat = '\%(| \)'
let s:depthstrmarkedpat = '\%(|[+\#]\)'
let s:depthstryankedpat = '\%(|-\)'
let s:separator = "'"  " separates depth and file type from file name
let s:seppat = "'"     " in case separator is a special character


syntax clear
syntax spell notoplevel
exe 'syntax match fm_regularfile  ".*'.s:seppat.'$"     contains=fm_depth,fm_marked,fm_yanked,fm_sepregfile'
exe 'syntax match fm_directory    ".*'.s:seppat.'/$"    contains=fm_depth,fm_marked,fm_yanked,fm_ftypeind'
exe 'syntax match fm_executable   ".*'.s:seppat.'\*$"   contains=fm_depth,fm_marked,fm_yanked,fm_ftypeind'
exe 'syntax match fm_symlink      ".*'.s:seppat.'@$"    contains=fm_depth,fm_marked,fm_yanked,fm_ftypeind'
exe 'syntax match fm_symlinkmis   ".*'.s:seppat.'!@$"   contains=fm_depth,fm_marked,fm_yanked,fm_ftypeind'
exe 'syntax match fm_socket       ".*'.s:seppat.'=$"    contains=fm_depth,fm_marked,fm_yanked,fm_ftypeind'
exe 'syntax match fm_fifo         ".*'.s:seppat.'|$"    contains=fm_depth,fm_marked,fm_yanked,fm_ftypeind'
exe 'syntax match fm_ftypeind     "'.s:seppat.'\%([\*@=|/]\|!@\)$"  contains=fm_sepftype contained'
exe 'syntax match fm_sepftype     "'.s:seppat.'\ze[\*@=|/]$"        conceal contained'
exe 'syntax match fm_sepftype     "'.s:seppat.'!\ze@$"              conceal contained'
exe 'syntax match fm_sepregfile   "'.s:seppat.'$"                   conceal contained'
exe 'syntax match fm_depth        "^'.s:depthstronlypat.'\+'.s:seppat.'"    contains=fm_sepdepth contained'
exe 'syntax match fm_marked       "^'.s:depthstrmarkedpat.'\+'.s:seppat.'"  contains=fm_sepdepth contained'
exe 'syntax match fm_yanked       "^'.s:depthstryankedpat.'\+'.s:seppat.'"  contains=fm_sepdepth contained'
exe 'syntax match fm_sepdepth     "^'.s:depthstrpat.'\+\zs'.s:seppat.'"     conceal contained'

highlight link fm_regularfile     Normal
highlight link fm_directory       Directory
highlight link fm_executable      Question
highlight link fm_symlink         Identifier
highlight link fm_symlinkmis      WarningMsg
highlight link fm_socket          PreProc
highlight link fm_fifo            Statement
highlight link fm_ftypeind        NonText
highlight link fm_depth           NonText
highlight link fm_marked          Search
highlight link fm_yanked          Visual
highlight link fm_sepdepth        NonText
highlight link fm_sepftype        NonText
highlight link fm_sepregfile      NonText

syntax match fm_rename_info     '\%^Edit .*$'  contains=fm_rename_button,fm_rename_nontext
syntax match fm_rename_button   'Enter'        contained
syntax match fm_rename_button   'Esc'          contained
syntax match fm_rename_nontext  'NonText'      contained

highlight link fm_rename_info     Statement
highlight link fm_rename_button   PreProc
highlight link fm_rename_nontext  NonText
