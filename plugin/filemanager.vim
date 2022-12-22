" filemanager - file explorer and manager plugin for Vim and Neovim intended
" to be as straightforward as possible and never do anything unexpected.
"
" Author: Kerim Guseynov
" URL: https://github.com/ehhov/filemanager
"

if exists('g:loaded_filemanager')
	finish
endif
let g:loaded_filemanager = 1


" Internal magic {{{
command! -bang -nargs=? -count=0 -complete=dir  L  call s:spawn(<q-args>, <bang>0, <count>, 1)
command! -bang -nargs=? -count=0 -complete=dir  V  call s:spawn(<q-args>, <bang>0, <count>, 1)
command! -bang -nargs=? -count=0 -complete=dir  H  call s:spawn(<q-args>, <bang>0, <count>, 0)


" Validity checked in s:checkconfig()
let s:opencmd              = get(g:, 'filemanager_opencmd',     'xdg-open')
let s:winsize              = get(g:, 'filemanager_winsize',             20)
let s:preferleft           = get(g:, 'filemanager_preferleft',           1)
let s:preferbelow          = get(g:, 'filemanager_preferbelow',          1)
let s:vertical             = get(g:, 'filemanager_vertical',             1)
let s:alwaysfixwinsize     = get(g:, 'filemanager_alwaysfixwinsize',     1)
let s:enablemouse          = get(g:, 'filemanager_enablemouse',          1)
let s:bookmarkonbufexit    = get(g:, 'filemanager_bookmarkonbufexit',    1)
let s:usebookmarkfile      = get(g:, 'filemanager_usebookmarkfile',      1)
let s:writebackupbookmarks = get(g:, 'filemanager_writebackupbookmarks', 0)
let s:writeshortbookmarks  = get(g:, 'filemanager_writeshortbookmarks',  1)
let s:notifyoffilters      = get(g:, 'filemanager_notifyoffilters',      1)
let s:skipfilterdirs       = get(g:, 'filemanager_skipfilterdirs',       0)
let s:settabdir            = get(g:, 'filemanager_settabdir',  !&autochdir)
let s:showhidden           = get(g:, 'filemanager_showhidden',           1)
let s:respectgitignore     = get(g:, 'filemanager_respectgitignore',     1)
let s:respectwildignore    = get(g:, 'filemanager_respectwildignore',    0)
let s:ignorecase           = get(g:, 'filemanager_ignorecase',          '')
let s:sortmethod           = get(g:, 'filemanager_sortmethod',      'name')
let s:newestfirst          = get(g:, 'filemanager_newestfirst',          1)
let s:sortfunc             = get(g:, 'filemanager_sortfunc',            '')
let s:sortrules            = get(g:, 'filemanager_sortrules',           {})
let s:sortorder = get(g:, 'filemanager_sortorder', '*/,*,.*/,.*,^__pycache__/$,\.bak$,\.swp$,\~$')
" The following lines must be the same as in syntax/filemanager.vim
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


" Just <abuf> doesn't work. More autocmds in s:initialize() and elsewhere
aug filemanager
	au!
	au VimEnter           *  silent! au! FileExplorer
	au VimEnter,BufEnter  *  call s:enter(expand('<afile>:p'), str2nr(expand('<abuf>')))
	if s:usebookmarkfile
		au VimEnter     *  silent call s:loadbookmarks()
		au VimLeavePre  *  call s:writebookmarks(2)
	endif
aug END


let s:filetypepat = '\%([\*@=|/]\|!@\|\)'

let s:tabvars = ['sortorder', 'sortmethod', 'sortreverse', 'usesortrules',
                \'ignorecase', 'skipfilterdirs', 'respectgitignore',
                \'showhidden', 'vertical', 'winsize']
let s:sortreverse = 0   " for uniformity in s:initialize() and s:exit()
let s:usesortrules = 1  " for uniformity as well

" Required to be able to move filemanager windows between tabs
let s:buflist = []

" Script-wide marked items: yanked
let s:yanked = []
let s:yankedtick = 0

" '' key for s:fixoldbookmarks()
let s:bookmarks = {'': 1}
" Should agree with s:bookmarksave()
let s:bookmarkvars = ['bak', 'cursor', 'opendirs', 'treeroot', 'filters', 'marked'] + s:tabvars
let s:bookmarknames = "'".'"0123456789qwertyuiopasdfghjklzxcvbnmQWERTYUIOPASDFGHJKLZXCVBNM[]{};:,.<>/?\!@#$%^&*()-_=+`~'
let s:bookmarknames = map(range(len(s:bookmarknames)), 's:bookmarknames[v:val]')
if s:usebookmarkfile
	if has('nvim')
		let s:bookmarkfile = stdpath('cache').'/filemanagerbookmarks'
	else
		let s:bookmarkfile = getenv('HOME').'/.vim/.filemanagerbookmarks'
	endif
else
	let s:bookmarkfile = ''
endif
"}}}


" Directory listing {{{
fun! s:pathexists(path, alllinks)  " {{{
	let l:wildignorecasesave = &wildignorecase
	let l:fileignorecasesave = &fileignorecase
	set nowildignorecase nofileignorecase
	let l:ret = !empty(glob(escape(fnameescape(a:path), '~'), 1, 0, a:alllinks))
	let &wildignorecase = l:wildignorecasesave
	let &fileignorecase = l:fileignorecasesave
	return l:ret
endfun  " }}}


fun! s:filterexisting(list)  " {{{
	let l:wildignorecasesave = &wildignorecase
	let l:fileignorecasesave = &fileignorecase
	set nowildignorecase nofileignorecase
	call filter(a:list, '!empty(glob(escape(fnameescape(v:val), "~"), 1, 0, 1))')
	let &wildignorecase = l:wildignorecasesave
	let &fileignorecase = l:fileignorecasesave
	return a:list
endfun  " }}}


fun! s:dirreadable(path)  " {{{
	return isdirectory(a:path) && s:pathexists(a:path.'/.', 1)
endfun  " }}}


fun! s:simplify(path)  " {{{
	" Vim's simplify() doesn't resolve symlink/..
	let l:split = split(simplify(a:path), '/\.\.\(/\|$\)', 1)
	while len(l:split) > 1
		if getftype(l:split[0]) == 'link'
			let l:split[0] = fnamemodify(resolve(l:split[0]), ':h').'/'.remove(l:split, 1)
		else
			let l:split[0] .= '/'.remove(l:split, 1)
		endif
	endwhile
	if a:path[-1:-1] == '/' && l:split[0][-1:-1] != '/'
		let l:split[0] .= '/'
	elseif a:path[-1:-1] != '/' && l:split[0][-1:-1] == '/'
		let l:split[0] = l:split[0][:-2]
	endif
	return l:split[0]
endfun  " }}}


fun! s:getdircontents(path)  " {{{
	let l:path = escape(fnameescape(a:path), '~')
	let l:dic = {'': getftime(a:path)}
	let l:ignored = ['.', '..']
	if b:fm_respectgitignore
		let l:gitignored = systemlist('cd '.shellescape(a:path, 0).' && git check-ignore * .*')
		if !v:shell_error
			let l:ignored += l:gitignored
		endif
	endif
	let l:wildignorecasesave = &wildignorecase
	let l:fileignorecasesave = &fileignorecase
	set nowildignorecase nofileignorecase
	let l:list = glob(l:path.'/*', !s:respectwildignore, 1, 1)
	if b:fm_showhidden
		let l:list += glob(l:path.'/.*', !s:respectwildignore, 1, 1)
	endif
	let &wildignorecase = l:wildignorecasesave
	let &fileignorecase = l:fileignorecasesave
	for l:item in l:list
		let l:dic[fnamemodify(l:item, ':t')] = isdirectory(l:item) ? {} : 0
	endfor
	" This was measured to be (slightly) faster at any length of l:ignored
	for l:ex in l:ignored
		if has_key(l:dic, l:ex)
			call remove(l:dic, l:ex)
		endif
	endfor
	return l:dic
endfun  " }}}


fun! s:sortbyname(list, path, sortorder)  " {{{
	let l:splitsortorder = split(a:sortorder, '[^\\]\zs,')
	call map(l:splitsortorder, 'substitute(v:val, "\\\\,", ",", "g")')
	let l:matches = add(map(copy(l:splitsortorder), '[]'), [])
	let l:rest = [[], [], [], []]
	let l:restid = [index(l:splitsortorder, '*/'), index(l:splitsortorder, '*'),
	               \index(l:splitsortorder, '.*/'), index(l:splitsortorder, '.*')]
	for l:i in filter(copy(l:restid), 'v:val != -1')
		let l:splitsortorder[l:i] = ''
	endfor
	for l:name in a:list
		let l:matchname = getftype(a:path.l:name) == 'dir' ? l:name.'/' : l:name
		let l:i = 0
		for l:pat in l:splitsortorder
			if l:pat != '' && match(l:matchname, '\C'.l:pat) != -1
				let l:i = -l:i - 1
				break
			endif
			let l:i += 1
		endfor
		if l:i < 0
			call add(l:matches[-l:i-1], l:name)
		else
			call add(l:rest[(l:matchname[-1:-1] != '/')
			               \+2*(l:matchname[0] == '.')], l:name)
		endif
	endfor
	for [l:i, l:j] in [[2, (l:restid[3] == -1 ? 0 : 3)], [0, 1], [3, 1]]
		if l:restid[l:i] == -1
			let l:rest[l:j] += l:rest[l:i]
			call filter(l:rest[l:i], 0)
		endif
	endfor
	for l:i in filter(range(4), '!empty(l:rest[v:val])')
		let l:matches[l:restid[l:i]] = l:rest[l:i]
	endfor
	let l:sorted = []
	for l:sublist in l:matches
		let l:sorted += sort(l:sublist, s:sortfunc)
	endfor
	return l:sorted
endfun  " }}}


fun! s:sortbytime(list, path, newest)  " {{{
	let l:list = map(a:list, 'getftime(a:path.v:val)." ".v:val')
	call map(sort(l:list, 'N'), 'substitute(v:val, "^-\\?\\d* ", "", "")')
	return a:newest ? reverse(l:list) : l:list
endfun  " }}}


fun! s:getsortrule(path)  " {{{
	if !b:fm_usesortrules
		return b:fm_sortmethod
	endif
	for [l:pat, l:rule] in items(s:sortrules)
		if match(a:path, '\C'.l:pat) != -1
			return l:rule
		endif
	endfor
	return b:fm_sortmethod
endfun  " }}}


fun! s:sort(dic, path)  " {{{
	let l:rule = s:getsortrule(a:path == '/' ? '/' : a:path[:-2])
	if l:rule[:3] == 'name' || (l:rule[:3] == 'obey' && b:fm_sortmethod == 'name')
		let l:order = len(l:rule) > 5 ? l:rule[5:] : b:fm_sortorder
		let l:sorted = s:sortbyname(keys(a:dic), a:path, l:order)
	else
		let l:order = l:rule[:3] == 'time' && len(l:rule) > 5 ?
		              \(l:rule[5] == 'n') : s:newestfirst
		let l:sorted = s:sortbytime(keys(a:dic), a:path, l:order)
	endif
	return b:fm_sortreverse ? reverse(l:sorted) : l:sorted
endfun  " }}}


fun! s:printcontents(dic, path, depth, linenr)  " {{{
	let b:fm_maxdepth = a:depth > b:fm_maxdepth ? a:depth : b:fm_maxdepth
	let l:linenr = a:linenr

	for l:name in s:sort(a:dic, a:path)
		let l:ftype = getftype(a:path.l:name)
		if l:name == ''
			" This is where timestamps are stored
			if len(a:dic) > 1
				continue
			endif
			" Directory was empty
			let l:line = s:separator
		elseif executable(a:path.l:name) && l:ftype != 'link' && l:ftype != 'dir'
			let l:line = l:name.s:separator.'*'
		elseif l:ftype == 'file'
			let l:line = l:name.s:separator
		elseif l:ftype == 'dir'
			let l:line = l:name.s:separator.'/'
		elseif l:ftype == 'link' && s:pathexists(a:path.l:name, 0)
			let l:line = l:name.s:separator.'@'
		elseif l:ftype == 'link'
			let l:line = l:name.s:separator.'!@'
		elseif l:ftype == 'socket'
			let l:line = l:name.s:separator.'='
		elseif l:ftype == 'fifo'
			let l:line = l:name.s:separator.'|'
		else
			let l:line = l:name.s:separator
		endif

		let l:m = index(b:fm_marked, a:path.l:name) != -1
		let l:y = index(s:yanked, a:path.l:name) != -1
		if l:m && l:y
			let l:line = repeat(s:depthstrmarknyanked, a:depth).s:separator.l:line
		elseif l:m
			let l:line = repeat(s:depthstrmarked, a:depth).s:separator.l:line
		elseif l:y
			let l:line = repeat(s:depthstryanked, a:depth).s:separator.l:line
		else
			let l:line = repeat(s:depthstr, a:depth).s:separator.l:line
		endif

		call setline(l:linenr, l:line)
		let l:linenr += 1

		let l:contents = a:dic[l:name]
		if type(l:contents) == v:t_dict && !empty(l:contents)
			let l:linenr = s:printcontents(l:contents, a:path.l:name.'/', a:depth+1, l:linenr)
		endif
	endfor

	return l:linenr
endfun  " }}}


fun! s:filtercontents(dic, relpath, depth)  " {{{
	let l:filtered = {}
	for [l:name, l:contents] in items(a:dic)
		if type(l:contents) == v:t_dict && !empty(l:contents)
			let l:contents = s:filtercontents(l:contents, a:relpath.l:name.'/', a:depth+1)
			" No need to check if name matches when contents do
			if len(l:contents) > 1
				let l:filtered[l:name] = l:contents
				continue
			endif
		endif
		if l:name == '' || (type(l:contents) == v:t_dict && b:fm_skipfilterdirs > a:depth)
			let l:filtered[l:name] = l:contents
			continue
		endif
		let l:all = 1
		for l:pattern in b:fm_filters
			if (l:pattern[0] !=# '!') == (match('/'.a:relpath.l:name, b:fm_ignorecase.l:pattern[1:]) == -1)
				let l:all = 0
				break
			endif
		endfor
		if l:all
			let l:filtered[l:name] = l:contents
		endif
	endfor
	return l:filtered
endfun  " }}}


fun! s:setbufname()  " {{{
	" Buffer number required for uniqueness
	let l:str = '[filemanager:'.bufnr().(b:fm_auxiliary ? ':AUX' : '')
	let l:str .= (exists('b:fm_renamefrom') ? ':RENAME' : '').']'
	silent exe 'file '.fnameescape(l:str.' '.b:fm_treeroot)
endfun  " }}}


fun! s:printtree(restview, movetopath='', movetotwo=0)  " {{{
	let b:fm_yankedticksave = s:yankedtick
	let b:fm_markedticksave = b:fm_markedtick
	let b:fm_maxdepth = 0
	if a:restview
		let l:winview = winsaveview()
	endif
	setl modifiable noreadonly
	silent %delete _
	call setline(1, '..'.s:separator.'/')
	call setline(2, fnamemodify(b:fm_treeroot, ':h:t').s:separator.'/')
	if empty(b:fm_filters)
		call s:printcontents(b:fm_tree, b:fm_treeroot, 1, 3)
	else
		call s:printcontents(s:filtercontents(b:fm_tree, '', 0), b:fm_treeroot, 1, 3)
	endif
	setl nomodifiable readonly nomodified
	if s:settabdir && !b:fm_auxiliary
		if s:dirreadable(b:fm_treeroot)
			exe 'tcd '.fnameescape(b:fm_treeroot)
		else
			echo 'Permission denied'
		endif
	endif
	call s:setbufname()
	if s:notifyoffilters && !empty(b:fm_filters)
		echo 'Filters active'
	endif
	if a:restview
		call winrestview(l:winview)
	endif
	if a:movetopath != '' && s:movecursorbypath(a:movetopath) && a:movetotwo
		call cursor(2, 1)
	endif
endfun  " }}}


fun! s:undercursor(keeptrailslash, linenr=-1)  " {{{
	let l:linenr = a:linenr < 0 ? line('.') : a:linenr

	if l:linenr == 1
		return fnamemodify(b:fm_treeroot, ':h:h')
	elseif l:linenr == 2
		return fnamemodify(b:fm_treeroot, ':h')
	endif

	let l:path = ''
	let l:depth = v:numbermax

	while l:depth > len(s:depthstr) + len(s:separator)
		let l:line = getline(l:linenr)
		let l:nodepth = substitute(l:line, '^'.s:depthstrpat.'*'.s:seppat, '', '')
		let l:curdepth = len(l:line) - len(l:nodepth)
		let l:linenr -= 1
		if l:depth > l:curdepth
			let l:path = '/'.substitute(l:nodepth, s:seppat.s:filetypepat.'$', '', '').l:path
			let l:depth = l:curdepth
		endif
	endwhile

	return b:fm_treeroot[:-2].(!a:keeptrailslash && l:path[-1:-1] == '/' ? l:path[:-2] : l:path)
endfun  " }}}


fun! s:undercursorlist(keeptrailslash, linenrlist, lines=0, shift=0)  " {{{
	let l:paths = []
	let l:depths = []
	call reverse(a:linenrlist)

	while !empty(a:linenrlist)
		let l:linenr = remove(a:linenrlist, 0)
		call insert(l:paths, '')
		call insert(l:depths, v:numbermax)
		while !empty(filter(l:depths, 'v:val > len(s:depthstr) + len(s:separator)'))
			if !empty(a:linenrlist) && l:linenr == a:linenrlist[0]
				call insert(l:paths, '')
				call insert(l:depths, v:numbermax)
				call remove(a:linenrlist, 0)
			endif
			let l:line = type(a:lines) == v:t_list ? a:lines[l:linenr-a:shift] : getline(l:linenr)
			let l:nodepth = substitute(l:line, '^'.s:depthstrpat.'*'.s:seppat, '', '')
			let l:curdepth = len(l:line) - len(l:nodepth)
			let l:linenr -= 1
			for l:i in filter(range(len(l:depths)), 'l:depths[v:val] > l:curdepth')
				let l:paths[l:i] = '/'.substitute(l:nodepth, s:seppat.s:filetypepat.'$', '', '').l:paths[l:i]
				let l:depths[l:i] = l:curdepth
			endfor
		endwhile
	endwhile
	return map(l:paths, 'b:fm_treeroot[:-2].(!a:keeptrailslash && v:val[-1:-1] == "/" ? v:val[:-2] : v:val)')
endfun  " }}}


fun! s:movecursorbypath(path)  " {{{
	let l:list = split(a:path[len(b:fm_treeroot):], '/')
	if empty(l:list)
		call cursor(2, 1)
		return 0
	endif
	let l:depth = 0
	let l:linenr = 2
	let l:lastnr = line('$')
	for l:name in l:list
		let l:linenr += 1
		let l:depth += 1
		while 1
			if match(getline(l:linenr), '\C^'.s:depthstrpat.'\{'.l:depth.'}'.s:seppat.'\V'.escape(l:name, '\').'\m'.s:seppat.s:filetypepat.'$') != -1
				break
			endif
			if match(getline(l:linenr), '\C^'.s:depthstrpat.'\{'.l:depth.'}') == -1 || l:linenr >= l:lastnr
				echo 'Path not visible or non-existent: "'.a:path.'"'
				return 1
			endif
			let l:linenr += 1
		endwhile
	endfor
	let l:linenr += (a:path[-1:-1] == '/')
	call cursor(l:linenr, 0)
	return 0
endfun  " }}}


fun! s:movetreecontents(from, to)  " {{{
	let l:to = s:simplify(a:to)
	if l:to[:len(b:fm_treeroot)-1] !=# b:fm_treeroot
		return
	endif
	let l:dicfrom = b:fm_tree
	let l:split = split(a:from[len(b:fm_treeroot):], '/')
	let l:namefrom = remove(l:split, -1)
	for l:name in l:split
		let l:dicfrom = l:dicfrom[l:name]
	endfor
	let l:dicto = b:fm_tree
	let l:split = split(l:to[len(b:fm_treeroot):], '/')
	let l:nameto = remove(l:split, -1)
	for l:name in l:split
		if !has_key(l:dicto, l:name)
			return
		endif
		let l:dicto = l:dicto[l:name]
	endfor
	let l:dicto[l:nameto] = remove(l:dicfrom, l:namefrom)
endfun  " }}}


fun! s:toggledir(path, operation, dontprint=0)  " {{{
	" operation: 0 = toggle, 1 = fold, 2 = unfold
	if a:operation == 0 && line('.') == 1
		call s:parentdir()
		return 0
	elseif a:operation == 0 && line('.') == 2
		call s:refreshtree(1)
		return 0
	endif

	let l:list = split(a:path[len(b:fm_treeroot):], '/')

	if a:operation != 2 && empty(l:list)
		echo 'Cannot fold the whole tree'
		return 1
	endif

	let l:dic = b:fm_tree
	for l:name in l:list
		let l:dic = get(l:dic, l:name, 0)
		if type(l:dic) != v:t_dict
			echo '"'.a:path.'" is not a directory'
			return 1
		endif
	endfor

	if empty(l:dic)
		if a:operation == 1
			" Currently unreachable (see s:folddir())
			echo 'Already folded'
			return 1
		endif
		call extend(l:dic, s:getdircontents(a:path))
	else
		if a:operation == 2
			echo 'Nothing to unfold'
			return 1
		endif
		call filter(l:dic, 0)
	endif

	if !a:dontprint
		call s:printtree(1)
	endif
	return 0
endfun  " }}}


fun! s:folddir(path, recursively)  " {{{
	if a:recursively
		let l:path = split(a:path[len(b:fm_treeroot):], '/')
		if len(l:path) < 2
			let l:path = b:fm_treeroot
		else
			let l:path = b:fm_treeroot.l:path[0]
		endif
	else
		let l:path = fnamemodify(a:path, ':h')
	endif
	if !s:toggledir(l:path, 1)
		call s:movecursorbypath(l:path)
	endif
endfun  " }}}


fun! s:foldcontentsbydepth(tree, depth, limit)  " {{{
	if a:depth > a:limit
		return filter(a:tree, 0)
	endif
	for l:dic in filter(values(a:tree), 'type(v:val) == v:t_dict && !empty(v:val)')
		call s:foldcontentsbydepth(l:dic, a:depth+1, a:limit)
	endfor
endfun  " }}}


fun! s:foldbydepth(decrease)  " {{{
	if b:fm_maxdepth == 1
		echo 'Nothing left to fold'
		return
	endif
	let l:limit = a:decrease > 0 && b:fm_maxdepth > a:decrease ? b:fm_maxdepth - a:decrease : 1
	let l:path = split(s:undercursor(1)[len(b:fm_treeroot):], '/', 1)
	let l:path = b:fm_treeroot.join(l:path[:l:limit-1], '/')
	call s:foldcontentsbydepth(b:fm_tree, 1, l:limit)
	call s:printtree(1, l:path, 0)
endfun  " }}}


fun! s:descenddir(path, onlyone)  " {{{
	if a:path ==# fnamemodify(b:fm_treeroot, ':h')
	   \|| a:path ==# fnamemodify(b:fm_treeroot, ':h:h')
		echo 'Unable to descend upwards'
		return
	elseif a:path[:len(b:fm_treeroot)-1] !=# b:fm_treeroot
		" Happens when the user tries to s:openbyname() by abs. path
		echo 'Directory out of reach: "'.a:path.'"'
		return
	endif
	let l:list = split(a:path[len(b:fm_treeroot):], '/')
	if !isdirectory(a:path) && !empty(l:list)
		call remove(l:list, -1)
	endif
	if empty(l:list)
		echo 'Nowhere to descend'
		return
	endif
	if a:onlyone
		call filter(l:list, 'v:key == 0')
	endif

	let l:setcol = 1
	for l:name in l:list
		" Happens when s:openbyname() a deep not visible directory
		if !has_key(b:fm_tree, l:name)
			let b:fm_tree = s:getdircontents(a:path)
			let l:setcol = 0
			break
		endif
		let b:fm_tree = b:fm_tree[l:name]
	endfor
	let b:fm_treeroot = b:fm_treeroot.join(l:list, '/').'/'
	if empty(b:fm_tree)
		let b:fm_tree = s:getdircontents(b:fm_treeroot)
	endif

	let l:winview = winsaveview()
	call s:printtree(0)
	if !s:movecursorbypath(a:path) && l:setcol
		call filter(l:winview, 'v:key == "col" || v:key == "coladd" || v:key == "curswant"')
		let l:winview['col'] -= len(s:depthstr) * len(l:list)
		let l:winview['curswant'] -= len(s:depthstr) * len(l:list)
		call winrestview(l:winview)
	elseif line('.') == 1  " path was not found
		call cursor(2, 1)
	endif
endfun  " }}}


fun! s:parentdir()  " {{{
	if b:fm_treeroot == '/'
		echo 'Already in the uppermost directory'
		return
	endif
	let l:setcol = line('.') > 2
	let l:path = s:undercursor(1, line('.') > 2 ? line('.') : 2)
	let l:oldtree = b:fm_tree
	let l:newroot = fnamemodify(b:fm_treeroot, ':h:h')
	let l:oldrootname = fnamemodify(b:fm_treeroot, ':h:t')
	let b:fm_treeroot = l:newroot == '/' ? '/' : l:newroot.'/'
	let b:fm_tree = s:getdircontents(b:fm_treeroot)
	if type(get(b:fm_tree, l:oldrootname, 0)) == v:t_dict
		let b:fm_tree[l:oldrootname] = l:oldtree
	endif
	let l:winview = winsaveview()
	call s:printtree(0)
	if !s:movecursorbypath(l:path) && l:setcol
		call filter(l:winview, 'v:key == "col" || v:key == "coladd" || v:key == "curswant"')
		let l:winview['col'] += len(s:depthstr)
		let l:winview['curswant'] += len(s:depthstr)
		call winrestview(l:winview)
	elseif line('.') == 1  " path was not found
		call cursor(2, 1)
	endif
endfun  " }}}


fun! s:refreshcontents(dic, path, force)  " {{{
	if !a:force && getftime(a:path) == a:dic['']
		let l:anyupdated = 0
		for [l:name, l:contents] in items(a:dic)
			if type(l:contents) == v:t_dict && !empty(l:contents)
				let [l:updated, a:dic[l:name]] = s:refreshcontents(l:contents, a:path.l:name.'/', a:force)
				let l:anyupdated = l:updated ? 1 : l:anyupdated
			endif
		endfor
		return [l:anyupdated, a:dic]
	endif
	let l:newtree = s:getdircontents(a:path)
	for l:name in keys(l:newtree)
		let l:contents = get(a:dic, l:name, 0)
		if type(l:contents) == v:t_dict && !empty(l:contents)
			let l:newtree[l:name] = s:refreshcontents(l:contents, a:path.l:name.'/', a:force)[1]
		endif
	endfor
	return [1, l:newtree]
endfun  " }}}


fun! s:refreshtree(force)  " {{{
	let l:refreshed = s:refreshcontents(b:fm_tree, b:fm_treeroot, a:force > 0)
	if l:refreshed[0] == 0
		if a:force < 0 || b:fm_yankedticksave < s:yankedtick
		   \ || b:fm_markedticksave < b:fm_markedtick
			call s:printtree(1, s:undercursor(1), 0)
		endif
		return
	endif
	" simplify() required only after renaming by tree
	let l:path = s:simplify(s:undercursor(1))
	let b:fm_tree = l:refreshed[1]
	call s:printtree(1, (l:path[:len(b:fm_treeroot)-1] ==# b:fm_treeroot ? l:path : ''), 0)
endfun  " }}}


fun! s:toggleshowhidden()  " {{{
	let b:fm_showhidden = !b:fm_showhidden
	call s:refreshtree(1)
	echo 'Show hidden '.(b:fm_showhidden ? 'ON' : 'OFF')
endfun  " }}}


fun! s:togglerespectgitignore()  " {{{
	let b:fm_respectgitignore = !b:fm_respectgitignore
	call s:refreshtree(1)
	echo 'Respect .gitignore '.(b:fm_respectgitignore ? 'ON' : 'OFF')
endfun  " }}}


fun! s:setignorecase()  " {{{
	let l:choice = confirm("Configure ignore case in Filter, Mark, and Yank:",
	                      \"&Obey 'ignorecase'\n&Ignore\n&Don't ignore")
	if l:choice == 0
		return
	endif
	let b:fm_ignorecase = ['', '\c', '\C'][l:choice-1]
	call s:printtree(1, s:undercursor(1), 0)
endfun  " }}}


fun! s:setskipfilterdirs()  " {{{
	let b:fm_skipfilterdirs = b:fm_skipfilterdirs == 0 && v:count == 0 ? 1 : v:count
	call s:printtree(1, s:undercursor(1), 1)
	echo !b:fm_skipfilterdirs ? 'Directories not immune to filters'
	     \: 'Directories up to depth '.b:fm_skipfilterdirs.' immune to filters'
endfun  " }}}


fun! s:togglesortreverse()  " {{{
	let b:fm_sortreverse = !b:fm_sortreverse
	call s:printtree(1, s:undercursor(1), 0)
	echo 'Reverse sort order '.(b:fm_sortreverse ? 'ON' : 'OFF')
endfun  " }}}


fun! s:toggleusesortrules()  " {{{
	let b:fm_usesortrules = !b:fm_usesortrules
	call s:printtree(1, s:undercursor(1), 0)
	echo 'Using sort rules '.(b:fm_usesortrules ? 'ON' : 'OFF')
endfun  " }}}


fun! s:setsortmethod()  " {{{
	let l:choice = confirm("Set sort method:", "By &name\nBy &time")
	if l:choice == 0
		return
	endif
	let b:fm_sortmethod = ['name', 'time'][l:choice-1]
	call s:printtree(1, s:undercursor(1), 0)
endfun  " }}}


fun! s:setsortorder()  " {{{
	call inputsave()
	echo 'Current sort order:  "'.b:fm_sortorder.'"'
	let l:sortorder = input('Enter new sort order: ', b:fm_sortorder)
	call inputrestore()
	redraw
	if l:sortorder == ''
		echo 'Empty string supplied. Default sort order set'
		let l:sortorder = s:sortorder
	endif
	let b:fm_sortorder = s:checksortorder(l:sortorder)
	call s:printtree(1, s:undercursor(1), 0)
endfun  " }}}


fun! s:checksortorder(sortorder)  " {{{
	let l:validsortorder = []
	for l:pat in split(a:sortorder, '[^\\]\zs,')
		if l:pat == '*'|| l:pat == '*/' || l:pat == '.*' || l:pat == '.*/'
		   \|| !s:checkregex(substitute(l:pat, '\\,', ',', 'g'))
			call add(l:validsortorder, l:pat)
		endif
	endfor
	return join(l:validsortorder, ',')
endfun  " }}}


fun! s:checkregex(pattern)  " {{{
	try
		call match('', a:pattern)
	catch /^Vim\%((\a\+)\)\?:/
		echohl ErrorMsg
		echomsg 'Invalid regex "'.a:pattern.'". '.substitute(v:exception, '^Vim\%((\a\+)\)\?:', '', '')
		echohl None
		return 1
	endtry
	return 0
endfun  " }}}


fun! s:checkglob(pattern)  " {{{
	try
		call glob2regpat(a:pattern)
	catch /^Vim\%((\a\+)\)\?:/
		echohl ErrorMsg
		echomsg 'Invalid glob "'.a:pattern.'". '.substitute(v:exception, '^Vim\%((\a\+)\)\?:', '', '')
		echohl None
		return 1
	endtry
	return 0
endfun  " }}}


fun! s:convertpattern(pat, glob)  " {{{
	let l:pat = a:glob ? glob2regpat(a:pat) : a:pat
	let l:pat = l:pat[0] == '^' && l:pat[1] != '/' ? '/'.l:pat[1:] : l:pat
	if a:glob
		" Conversion tricks that make sense only together
		let l:pat = substitute(l:pat, '\(^\|/\)\.\*', '/[^/\\.][^/]*', 'g')
		let l:pat = substitute(l:pat, '\(^\|/\)\.', '/[^/\\.]', 'g')
		let l:pat = substitute(l:pat, '\.\*', '[^/]*', 'g')
		let l:pat = substitute(l:pat, '\(^\|[^\\]\)\zs\.', '[^/]', 'g')
	endif
	let l:pat = l:pat[-1:-1] == '$' ? l:pat : l:pat.'[^/]*$'
	return substitute(l:pat, '//\+', '/', 'g')
endfun  " }}}


fun! s:filtercmd(pattern, bang, glob)  " {{{
	if a:pattern == ''
		if empty(b:fm_filters)
			echo 'No filters applied'
			return
		endif
		if a:bang
			call filter(b:fm_filters, 0)
		else
			call remove(b:fm_filters, -1)
		endif
	else
		if a:glob ? s:checkglob(a:pattern) : s:checkregex(a:pattern)
			return
		endif
		call add(b:fm_filters, (a:bang ? '!' : ' ').s:convertpattern(a:pattern, a:glob))
	endif

	let l:path = s:undercursor(1)
	call s:printtree(0)
	silent eval s:movecursorbypath(l:path) && cursor(2, 1)
	if empty(b:fm_filters)
		echo 'All filters removed'
	endif
endfun  " }}}


fun! s:printfilters()  " {{{
	if empty(b:fm_filters)
		echo 'No filters applied'
	else
		echo 'Filters applied:'
		echo ' '.join(b:fm_filters, "\n ")
	endif
endfun  " }}}
" }}}


" Bookmark actions {{{
fun! s:opendirs(tree, relpath)  " {{{
	let l:list = []
	for l:name in s:sort(a:tree, b:fm_treeroot.a:relpath)
		let l:contents = a:tree[l:name]
		if type(l:contents) == v:t_dict && !empty(l:contents)
			call add(l:list, a:relpath.l:name)
			let l:list += s:opendirs(l:contents, a:relpath.l:name.'/')
		endif
	endfor
	return l:list
endfun  " }}}


fun! s:bookmarksave(name, bak)  " {{{
	if !a:bak && a:name ==# s:bookmarknames[0]
		call s:bookmarkbackup(bufnr())
		let s:bookmarks[a:name][index(s:bookmarkvars, 'bak')] = 0
	else
		let s:bookmarks[a:name] = map(copy(s:tabvars), 'eval("b:fm_".v:val)')
		call insert(s:bookmarks[a:name], string(b:fm_marked))
		call insert(s:bookmarks[a:name], string(b:fm_filters))
		call insert(s:bookmarks[a:name], b:fm_treeroot)
		call insert(s:bookmarks[a:name], s:opendirs(b:fm_tree, ''))
		call insert(s:bookmarks[a:name], s:undercursor(1))
		call insert(s:bookmarks[a:name], a:bak)
		if !a:bak
			echomsg 'Bookmark "'.a:name.'" saved'
		endif
	endif
endfun  " }}}


fun! s:bookmarkbackup(bufnr)  " {{{
	if exists('b:fm_changedticksave') && b:fm_changedticksave == b:changedtick
		return
	endif
	let l:bakind = index(s:bookmarkvars, 'bak')
	let l:shift = []
	for l:name in s:bookmarknames
		if has_key(s:bookmarks, l:name)
			if s:bookmarks[l:name][l:bakind]
				call insert(l:shift, l:name)
			endif
		else
			call insert(l:shift, l:name)
			break
		endif
	endfor
	while len(l:shift) > 1
		let s:bookmarks[l:shift[0]] = s:bookmarks[l:shift[1]]
		call remove(l:shift, 0)
	endwhile
	call win_execute(bufwinid(a:bufnr), 'call s:bookmarksave(l:shift[0], 1)')
endfun  " }}}


fun! s:bookmarkrestore(name)  " {{{
	if !has_key(s:bookmarks, a:name)
		echo 'No bookmark "'.a:name.'" saved'
		return
	endif
	let l:bookmark = s:bookmarks[a:name]
	call s:bookmarkbackup(bufnr())
	let l:i = index(s:bookmarkvars, s:tabvars[0])
	for l:var in s:tabvars
		call setbufvar(bufnr(), 'fm_'.l:var, l:bookmark[l:i])
		let l:i += 1
	endfor
	let b:fm_treeroot = l:bookmark[index(s:bookmarkvars, 'treeroot')]
	let b:fm_filters = eval(l:bookmark[index(s:bookmarkvars, 'filters')])
	let b:fm_marked = eval(l:bookmark[index(s:bookmarkvars, 'marked')])
	let b:fm_markedtick += 1
	let b:fm_tree = s:getdircontents(b:fm_treeroot)
	for l:path in l:bookmark[index(s:bookmarkvars, 'opendirs')]
		call s:toggledir(b:fm_treeroot.l:path, 2, 1)
	endfor
	call s:printtree(0, l:bookmark[index(s:bookmarkvars, 'cursor')], 1)
	let b:fm_changedticksave = b:changedtick
	echomsg 'Bookmark "'.a:name.'" restored'
endfun  " }}}


fun! s:printbookmarks()  " {{{
	if len(s:bookmarks) == 1
		echo 'No bookmarks saved'
		return
	endif
	let l:rootind = index(s:bookmarkvars, 'treeroot')
	let l:openind = index(s:bookmarkvars, 'opendirs')
	let l:bakind = index(s:bookmarkvars, 'bak')
	echo 'Bookmarks:'
	for l:name in sort(filter(keys(s:bookmarks), 'v:val != "" && index(s:bookmarknames, v:val) == -1'), s:sortfunc)
	          \ + filter(copy(s:bookmarknames), 'has_key(s:bookmarks, v:val) && !s:bookmarks[v:val][l:bakind]')
	          \ + filter(copy(s:bookmarknames), 'has_key(s:bookmarks, v:val) && s:bookmarks[v:val][l:bakind]')
		let l:prepend = (s:bookmarks[l:name][l:bakind] ? 'bak ' : '').l:name.': '
		echo l:prepend.'/'.s:bookmarks[l:name][l:rootind][1:-2]
		if !empty(s:bookmarks[l:name][l:openind])
			let l:indent = repeat(' ', len(l:prepend)+2)
			echo l:indent.join(s:bookmarks[l:name][l:openind], "\n".l:indent)
		endif
	endfor
endfun  " }}}


fun! s:writebookmarks(operation)  " {{{
	if s:writebackupbookmarks && s:writeshortbookmarks
		let l:bookmarks = s:bookmarks
	elseif s:writeshortbookmarks
		let l:bakind = index(s:bookmarkvars, 'bak')
		let l:bookmarks = filter(copy(s:bookmarks), 'v:key == "" || !v:val[l:bakind]')
	else
		let l:bookmarks = filter(copy(s:bookmarks), 'v:key == "" || index(s:bookmarknames, v:val) == -1')
	endif
	if a:operation != 1 && filereadable(s:bookmarkfile)
		let l:saved = readfile(s:bookmarkfile)
		if empty(l:saved) || empty(l:saved[0]) || empty(eval(l:saved[0]))
			let l:saved = l:bookmarks
		else
			let l:saved = eval(l:saved[0])
			call extend(l:saved, l:bookmarks)
		endif
	else
		let l:saved = l:bookmarks
	endif
	let l:err = 1
	try
		if !s:pathexists(fnamemodify(s:bookmarkfile, ':h'), 1)
			call mkdir(fnamemodify(s:bookmarkfile, ':h'), 'p')
		endif
		let l:err = writefile([string(l:saved)], s:bookmarkfile)
	finally
		" No error only when writefile() finishes and returns 0
		if l:err
			echohl ErrorMsg
			echomsg 'Failed to write bookmarks to file'
			echohl None
			" Make sure the user sees this on VimLeavePre
			if a:operation == 2
				call confirm("Error on VimLeave", "Seen")
			endif
			return 1
		endif
	endtry
	return 0
endfun  " }}}


fun! s:loadbookmarks()  " {{{
	if !filereadable(s:bookmarkfile)
		echohl ErrorMsg
		echomsg 'Bookmark file not readable or non-existent'
		echohl None
	else
		let l:saved = readfile(s:bookmarkfile)
		if empty(l:saved) || empty(l:saved[0]) || empty(eval(l:saved[0]))
			echo 'Bookmark file empty'
		else
			call extend(s:bookmarks, s:fixoldbookmarks(eval(l:saved[0])))
		endif
	endif
endfun  " }}}


fun! s:fixoldbookmarks(bookmarks)  " {{{
	for [l:name, l:bookmark] in items(a:bookmarks)
		if len(l:bookmark) == 15
			call insert(l:bookmark, string(s:usesortrules), 9)
		endif
	endfor
	if !has_key(a:bookmarks, '')
		for l:bookmark in values(a:bookmarks)
			let l:bookmark[11] = !l:bookmark[11]
		endfor
		let a:bookmarks[''] = 0
	endif
	if a:bookmarks[''] == 0
		for l:bookmark in values(filter(a:bookmarks, 'v:key != ""'))
			call map(l:bookmark, 'v:key == 3 || v:key > 5 ? eval(v:val) : v:val')
		endfor
		let a:bookmarks[''] = 1
	endif
	return a:bookmarks
endfun  " }}}


fun! s:dellocalbookmark(name)  " {{{
	if !has_key(s:bookmarks, a:name)
		return 1
	else
		call remove(s:bookmarks, a:name)
		echomsg 'Bookmark "'.a:name.'" deleted'
		return 0
	endif
endfun  " }}}


fun! s:delbookmarkfromfile(name)  " {{{
	let l:bookmarkssave = s:bookmarks
	let s:bookmarks = {}
	call s:loadbookmarks()
	if len(s:bookmarks) == 1
		let s:bookmarks = l:bookmarkssave
		return 1
	endif
	if has_key(s:bookmarks, a:name)
		call remove(s:bookmarks, a:name)
		let l:err = s:writebookmarks(1)
		if !l:err
			echomsg 'Bookmark "'.a:name.'" deleted from file'
		endif
	else
		echo 'No bookmark "'.a:name.'" saved in file'
		let l:err = 1
	endif
	let s:bookmarks = l:bookmarkssave
	return l:err
endfun  " }}}


fun! s:bookmarksuggest(arglead, cmdline, curpos)  " {{{
	let l:bakind = index(s:bookmarkvars, 'bak')
	let l:list = sort(filter(keys(s:bookmarks), 'v:val != "" && index(s:bookmarknames, v:val) == -1'), s:sortfunc)
	          \ + filter(copy(s:bookmarknames), 'has_key(s:bookmarks, v:val) && !s:bookmarks[v:val][l:bakind]')
	          \ + filter(copy(s:bookmarknames), 'has_key(s:bookmarks, v:val) && s:bookmarks[v:val][l:bakind]')
	          \ + ['load', 'write']
	return empty(a:arglead) ? l:list : filter(l:list, 'v:val[:len(a:arglead)-1] == a:arglead')
endfun  " }}}


fun! s:bookmarkdelsuggest(arglead, cmdline, curpos)  " {{{
	let l:bakind = index(s:bookmarkvars, 'bak')
	let l:list = sort(filter(keys(s:bookmarks), 'v:val != "" && index(s:bookmarknames, v:val) == -1'), s:sortfunc)
	          \ + filter(copy(s:bookmarknames), 'has_key(s:bookmarks, v:val) && !s:bookmarks[v:val][l:bakind]')
	          \ + filter(copy(s:bookmarknames), 'has_key(s:bookmarks, v:val) && s:bookmarks[v:val][l:bakind]')
	          \ + ['file']
	return empty(a:arglead) ? l:list : filter(l:list, 'v:val[:len(a:arglead)-1] == a:arglead')
endfun  " }}}


fun! s:bookmarkcmd(bang, arg)  " {{{
	if a:arg ==# 'write' && !empty(s:bookmarkfile)
		call s:writebookmarks(0)
	elseif a:arg ==# 'load' && !empty(s:bookmarkfile)
		call s:loadbookmarks()
	elseif a:arg ==# 'file' && !empty(s:bookmarkfile)
		echo 'Invalid bookmark name "'.a:arg.'"'
	elseif a:bang && a:arg != ''
		call s:bookmarksave(a:arg, 0)
	elseif a:arg != ''
		call s:bookmarkrestore(a:arg)
	else
		call s:printbookmarks()
	endif
endfun  " }}}


fun! s:bookmarkdel(bang, name)  " {{{
	if a:name ==# 'file' && a:bang && !empty(s:bookmarkfile)
		call s:bookmarkdel(a:bang, '')
		call s:bookmarkdel('', a:name)
	elseif a:name ==# 'file' && !empty(s:bookmarkfile)
		if !s:pathexists(s:bookmarkfile, 1)
			echomsg 'Bookmark file non-existent'
		elseif confirm("Delete bookmark file?", "&No\n&Yes") == 2 && delete(s:bookmarkfile)
			echohl ErrorMsg
			echomsg 'Failed to delete bookmark file'
			echohl None
		endif
	elseif (a:name ==# 'load' || a:name ==# 'write') && !empty(s:bookmarkfile)
		echo 'Invalid bookmark name "'.a:name.'"'
	elseif a:name != ''
		let l:err = s:dellocalbookmark(a:name)
		if a:bang && !empty(s:bookmarkfile)
			let l:err = s:delbookmarkfromfile(a:name) && l:err
		endif
		if l:err
			echo 'No bookmark "'.a:name.'" saved'
		endif
	elseif a:bang
		if len(s:bookmarks) == 1
			echo 'No bookmarks saved'
		elseif confirm("Delete all bookmarks?", "&No\n&Yes") == 2
			call filter(s:bookmarks, 'v:key == ""')
		endif
	endif
endfun  " }}}
" }}}


" File operations {{{
fun! s:newdir()  " {{{
	let l:path = fnamemodify(s:undercursor(1, line('.') > 3 ? line('.') : 3), ':h')
	if s:dirreadable(l:path)
		exe 'lcd '.fnameescape(l:path)
	endif
	call inputsave()
	let l:name = input('Enter new directory name: ', '', 'file')
	call inputrestore()
	redraw
	if l:name == ''
		echo 'Empty name supplied. Aborted'
		return
	endif

	let l:substring = matchstr(l:name, '^\s*\~[^/]*/')
	let l:name = substitute(l:name, '^\s*\~[^/]*/', expandcmd(l:substring), '')
	let l:name = l:name[0] == '/' ? l:name : substitute(l:path, '/$', '', '').'/'.l:name
	let l:name = s:simplify(l:name)
	if s:pathexists(l:name, 1)
		echo 'Path exists: "'.l:name.'"'
		return
	endif

	let l:outside = l:name[:len(b:fm_treeroot)-1] !=# b:fm_treeroot
	if l:outside && confirm("Create directory outside the current tree?", "&No\n&Yes") < 2
		return
	endif
	try
		call mkdir(l:name, 'p')
	catch /^Vim\%((\a\+)\)\?:E739/
		echo 'Failed to create directory "'.l:name.'"'
		return
	endtry
	if l:outside
		return
	endif
	let l:dirpath = b:fm_treeroot
	let b:fm_tree = s:refreshcontents(b:fm_tree, b:fm_treeroot, 0)[1]
	for l:dirstep in split(l:name[len(b:fm_treeroot):], '/')
		" Don't notify if already open
		silent call s:toggledir(l:dirpath.l:dirstep, 2, 1)
		let l:dirpath .= l:dirstep.'/'
	endfor
	call s:printtree(1, l:dirpath, 0)
endfun  " }}}


fun! s:openbyfind()  " {{{
	if s:dirreadable(b:fm_treeroot)
		exe 'lcd '.fnameescape(b:fm_treeroot)
	endif
	call inputsave()
	let l:name = input('Enter file name in path: ', '', 'file_in_path')
	call inputrestore()
	redraw
	if l:name == ''
		echo 'Empty name supplied. Aborted'
		return
	endif

	let l:winsize = b:fm_winsize
	let l:vertical = b:fm_vertical
	let l:autochdirsave = &autochdir
	set noautochdir
	if b:fm_auxiliary
		let l:cleanupcode = ''
	elseif winnr('#') == 0 || winnr('#') == winnr()
		silent new
		exe 'wincmd '.(l:vertical ? (s:preferleft ? 'L' : 'H')
		               \: (s:preferbelow ? 'K' : 'J'))
		exe (l:vertical ? 'vertical ' : '').'resize '
		    \.((100 - l:winsize) * (l:vertical ? &columns : &lines) / 100)
		let l:cleanupcode = 'silent close'
	else
		silent wincmd p
		let l:cleanupcode = 'silent wincmd p'
	endif

	try
		exe 'confirm '.v:count.'find '.fnameescape(l:name)
	catch /^Vim(find):/
		exe l:cleanupcode
		echohl ErrorMsg
		" Remove the leading Vim(find):
		echomsg v:exception[10:]
		echohl None
	finally
		let &autochdir = l:autochdirsave
	endtry
endfun  " }}}


fun! s:openbyname(external)  " {{{
	let l:path = fnamemodify(s:undercursor(1, line('.') > 3 ? line('.') : 3), ':h')
	if s:dirreadable(l:path)
		exe 'lcd '.fnameescape(l:path)
	endif
	call inputsave()
	let l:name = input('Enter file/directory name: ', '', 'file')
	call inputrestore()
	redraw
	if l:name == ''
		echo 'Empty name supplied. Aborted'
		return
	endif

	let l:substring = matchstr(l:name, '^\s*\~[^/]*/')
	let l:name = substitute(l:name, '^\s*\~[^/]*/', expandcmd(l:substring), '')
	let l:name = l:name[0] == '/' ? l:name : substitute(l:path, '/$', '', '').'/'.l:name

	if a:external
		call s:openexternal(s:simplify(l:name))
	else
		call s:open(s:simplify(l:name), -1)
	endif
endfun  " }}}


fun! s:open(path, mode)  " {{{
	if isdirectory(a:path)
		if a:mode == 0
			return s:toggledir(a:path, 0)
		elseif a:mode == -1
			return s:descenddir(a:path, 0)
		elseif a:mode != 4  " allow opening in a new tab
			echo '"'.a:path.'" is a directory'
			return
		endif
	" Don't list missing symlinks, otherwise they are always not readable
	elseif s:pathexists(a:path, 0) && !filereadable(a:path)
		echo '"'.a:path.'" is not readable'
		return
	endif

	if b:fm_auxiliary && a:mode != 4  " allow opening in a new tab
		exe 'edit '.fnameescape(a:path)
		return
	endif

	let l:winsize = b:fm_winsize

	if a:mode == 0 || a:mode == -1  " <enter> or by name
		if winnr('#') == 0 || winnr('#') == winnr()
			return s:open(a:path, b:fm_vertical ? 1 : 2)
		endif
		silent wincmd p
		exe 'confirm edit '.fnameescape(a:path)
	elseif a:mode == 1 || a:mode == 2  " single vertical/horizontal window
		" See note on :only in s:openterminal()
		try
			confirm only
			silent only
		catch /^Vim(only):/
			echohl ErrorMsg
			" Remove the leading Vim(only):
			echomsg v:exception[10:]
			echohl None
			return
		endtry
		let b:fm_vertical = (a:mode == 1)
		exe 'new '.fnameescape(a:path)
		exe 'wincmd '.(a:mode == 1 ? (s:preferleft ? 'L' : 'H')
		               \: (s:preferbelow ? 'K' : 'J'))
		exe (a:mode == 1 ? 'vertical ' : '').'resize '
		    \.((100 - l:winsize) * (a:mode == 1 ? &columns : &lines) / 100)
	elseif a:mode == 3  " above/below all and maximized
		exe 'new '.fnameescape(a:path)
		exe 'wincmd '.(s:preferbelow ? 'K' : 'J')
		resize
	elseif a:mode == 4  " new tab
		exe 'tab new '.fnameescape(a:path)
	elseif a:mode == 5 || a:mode == 6  " new horizontal/vertical split
		let l:vertical = b:fm_vertical
		let l:winview = winsaveview()
		exe 'new '.fnameescape(a:path)
		exe 'wincmd '.(a:mode == 5 ? (s:preferbelow == l:vertical ? 'K' : 'J')
		               \: (s:preferleft == l:vertical ? 'H' : 'L'))
		" :noautocmd should be safe when only resizing and returning
		noautocmd silent wincmd p
		exe 'wincmd '.(l:vertical ? (s:preferleft ? 'H' : 'L')
		               \: (s:preferbelow ? 'J' : 'K'))
		exe (l:vertical ? 'vertical ' : '').'resize '
		    \.(l:winsize * (l:vertical ? &columns : &lines) / 100)
		call winrestview(l:winview)
		noautocmd silent wincmd p
		wincmd =
	elseif a:mode == 7  " replace filemanager window
		exe 'edit '.fnameescape(a:path)
	endif
endfun  " }}}


fun! s:openterminal(cdundercursor)  " {{{
	if a:cdundercursor
		let l:path = fnamemodify(s:undercursor(1, line('.') > 3 ? line('.') : 3), ':h')
	else
		let l:path = b:fm_treeroot
	endif

	" :terminal randomly ignores local CWD and uses the tab-local one.
	" :tcd - seems to rely on something other than tab-local CWDs.
	" Try :tcd /tmp | new /usr/share/1 | tcd /var | tcd - | pwd
	let l:cdcmd = s:dirreadable(l:path) ? (s:settabdir ? 'tcd ' : 'lcd ').fnameescape(l:path) : ''
	let l:cdback = s:dirreadable(l:path) && s:settabdir ? 'tcd '.fnameescape(getcwd(-1, 0)) : ''

	if b:fm_auxiliary
		exe l:cdcmd
		if has('nvim')
			terminal
		else
			terminal ++curwin
		endif
		exe l:cdback
		return
	endif

	" There is no way to know what the user has chosen in :confirm.
	" Strangely, :only proceeds even when canceled under :confirm.
	" Although it is 'good' here and allows filemanager to know whether
	" the user has canceled the operation, the second :only is meant to do
	" this very job (just in case Vim ever decides to change this strange
	" behavior of :only).
	try
		confirm only
		silent only
	catch /^Vim(only):/
		echohl ErrorMsg
		" Remove the leading Vim(only):
		echomsg v:exception[10:]
		echohl None
		return
	endtry
	let l:vertical = b:fm_vertical
	let l:winsize = b:fm_winsize
	if has('nvim')
		silent new
	endif
	exe l:cdcmd
	terminal
	if l:vertical
		exe 'wincmd '.(s:preferleft ? 'L' : 'H')
		exe 'vertical resize '.((100 - l:winsize) * &columns / 100)
	else
		exe 'wincmd '.(s:preferbelow ? 'K' : 'J')
		exe 'resize '.((100 - l:winsize) * &lines / 100)
	endif
	exe l:cdback
endfun  " }}}


fun! s:cmdundercursor()  " {{{
	let l:path = fnamemodify(s:undercursor(1, line('.') > 3 ? line('.') : 3), ':h')
	if s:dirreadable(l:path)
		exe 'au filemanager CmdlineEnter <buffer> ++once lcd '.fnameescape(l:path)
		call feedkeys(':!')
	else
		echo 'Permission denied'
	endif
	" Tree refreshed on every ShellCmdPost anyway
endfun  " }}}


fun! s:openexternal(path)  " {{{
	silent let l:output = system('setsid -f '.s:opencmd.' '.shellescape(a:path, 0).' </dev/null >/dev/null 2>&1')
	if v:shell_error
		echo l:output
	endif
endfun  " }}}


fun! s:statcmd(path)  " {{{
	silent let l:output = system('stat '.shellescape(a:path, 0))
	echo l:output
endfun  " }}}


fun! s:filecmd(path)  " {{{
	silent let l:output = system('file '.shellescape(a:path, 0))
	echo substitute(l:output, '\n$', '', '')
endfun  " }}}
" }}}


" Multiple file operations {{{
fun! s:namematches(tree, relpath, pattern)  " {{{
	let l:list = []
	for [l:name, l:contents] in items(a:tree)
		if l:name != '' && match('/'.a:relpath.l:name, b:fm_ignorecase.a:pattern) != -1
			call add(l:list, b:fm_treeroot.a:relpath.l:name)
		endif
		if type(l:contents) == v:t_dict && !empty(l:contents)
			let l:list += s:namematches(l:contents, a:relpath.l:name.'/', a:pattern)
		endif
	endfor
	return l:list
endfun  " }}}


fun! s:markbypat(pattern, bang, glob, yank)  " {{{
	let l:list = a:yank ? s:yanked : b:fm_marked
	if empty(a:pattern) && empty(l:list)
		echo a:yank ? 'Yanked list empty' : 'Marked list empty'
		return
	elseif empty(a:pattern)
		echo a:yank ? 'Yanked items:' : 'Marked items:'
		echo ' '.join(l:list, "\n ")
		return
	endif
	if a:glob ? s:checkglob(a:pattern) : s:checkregex(a:pattern)
		return
	endif
	let l:oldlen = len(l:list)
	let l:tree = empty(b:fm_filters) ? b:fm_tree : s:filtercontents(b:fm_tree, '', 0)
	let l:matches = s:namematches(l:tree, '', s:convertpattern(a:pattern, a:glob))
	if a:bang
		call filter(map(l:matches, 'index(l:list, v:val)'), 'v:val != -1')
		for l:i in reverse(sort(l:matches, 'n'))
			call remove(l:list, l:i)
		endfor
	else
		call uniq(sort(extend(l:list, l:matches)))
	endif
	if l:oldlen != len(l:list)
		let b:fm_markedtick += !a:yank
		let s:yankedtick += a:yank
		call s:printtree(1)
	endif
endfun  " }}}


fun! s:mark(ends)  " {{{
	let l:presentpaths = []
	let l:oldlen = len(b:fm_marked)
	for l:path in uniq(map(filter(range(min(a:ends), max(a:ends)), 'v:val < 3'),
	                      \'s:undercursor(0, v:val)'))
	        echo 'Skipping "'.l:path.'"'
	endfor
	" uniq() for possible empty directories
	for l:path in uniq(s:undercursorlist(0, filter(range(min(a:ends), max(a:ends)), 'v:val > 2')))
		let l:i = index(b:fm_marked, l:path)
		if l:i == -1
			call add(b:fm_marked, l:path)
		else
			call add(l:presentpaths, l:i)
		endif
	endfor
	if len(b:fm_marked) == l:oldlen && empty(l:presentpaths)
		return
	elseif len(b:fm_marked) == l:oldlen
		for l:i in reverse(sort(l:presentpaths, 'n'))
			call remove(b:fm_marked, l:i)
		endfor
	endif
	let b:fm_markedtick += 1
	call s:printtree(1)
endfun  " }}}


fun! s:resetmarked()  " {{{
	if !empty(b:fm_marked)
		let b:fm_markedtick += 1
		call filter(b:fm_marked, 0)
		call s:printtree(1)
	endif
endfun  " }}}


fun! s:yankmarked(list=0)  " {{{
	let l:list = type(a:list) == v:t_list ? a:list : b:fm_marked
	if empty(l:list)
		if empty(s:yanked)
			echo 'Nothing to yank'
		else
			echo 'Nothing to yank. Currently yanked:'
			echo ' '.join(s:yanked, "\n ")
		endif
		return
	endif
	let l:oldlen = len(s:yanked)
	call uniq(sort(extend(s:yanked, l:list)))
	if len(s:yanked) == l:oldlen
		echo 'Nothing new yanked. Current list:'
		echo ' '.join(s:yanked, "\n ")
	else
		echo 'Yanked list extended by '.(len(s:yanked) - l:oldlen)
		     \.' (from '.l:oldlen.' to '.len(s:yanked).')'
		let s:yankedtick += 1
	endif
	if type(a:list) != v:t_list
		call filter(b:fm_marked, 0)
		let b:fm_markedtick += 1
	elseif len(s:yanked) == l:oldlen
		return
	endif
	call s:printtree(1)
endfun  " }}}


fun! s:resetyanked(list=0)  " {{{
	if empty(s:yanked)
		echo 'Nothing currently yanked'
		return
	endif
	let l:list = type(a:list) == v:t_list ? a:list : b:fm_marked
	if empty(l:list) && type(a:list) != v:t_list
		call filter(s:yanked, 0)
		echo 'Yanked list reset'
		let s:yankedtick += 1
		return s:printtree(1)
	elseif empty(l:list)
		echo 'Nothing to remove from yanked'
		return
	endif
	let l:oldlen = len(s:yanked)
	for l:path in l:list
		let l:i = index(s:yanked, l:path)
		if l:i == -1
			echo '"'.l:path.'" is not yanked'
		else
			call remove(s:yanked, l:i)
		endif
	endfor
	if len(s:yanked) == l:oldlen
		return
	endif
	echo 'Yanked list shrunk by '.(l:oldlen - len(s:yanked))
	     \.' (from '.l:oldlen.' to '.len(s:yanked).')'
	let s:yankedtick += 1
	if type(a:list) != v:t_list
		call filter(b:fm_marked, 0)
		let b:fm_markedtick += 1
	endif
	call s:printtree(1)
endfun  " }}}


fun! s:gotomarked(backwards)  " {{{
	" Separate function because <sid> doesn't work for variables
	call search('^'.s:depthstrmarkedpat, a:backwards ? 'bs' : 's')
endfun  " }}}


fun! s:pastemarked(leave, doyanked)  " {{{
	let l:list = a:doyanked ? s:yanked : b:fm_marked
	if empty(l:list)
		echo 'Nothing currently '.(a:doyanked ? 'yanked' : 'marked')
		return
	endif
	call sort(l:list, s:sortfunc)
	let l:destdir = fnamemodify(s:undercursor(1, line('.') > 3 ? line('.') : 3), ':h')
	let l:destdir = substitute(l:destdir, '/$', '', '').'/'

	let l:existing = map(copy(l:list), 'l:destdir.fnamemodify(v:val, ":t")')
	if !empty(s:filterexisting(l:existing))
		echo 'Destinations already exist:'
		echo ' '.join(l:existing, "\n ")
		if confirm("Overwrite?", "&No\n&Yes") < 2
			echo 'Nothing pasted'
			return
		endif
	endif

	echo 'Items to paste:'
	echo ' '.join(l:list, "\n ")
	if confirm("Paste?", "&No\n&Yes") < 2
		echo 'Operation canceled'
		return
	endif
	silent let l:output = system('cp -r '.join(map(add(copy(l:list), l:destdir),
	                                               \'shellescape(v:val, 0)'), ' '))
	if v:shell_error
		echohl ErrorMsg
		echomsg 'Failed to paste: '.l:output
		echohl None
	endif
	if !a:leave && !v:shell_error
		call filter(l:list, 0)
		let s:yankedtick += a:doyanked
		let b:fm_markedtick += !a:doyanked
	endif
	call s:refreshtree(0)
endfun  " }}}


fun! s:movemarked(doyanked)  " {{{
	let l:list = a:doyanked ? s:yanked : b:fm_marked
	if empty(l:list)
		echo 'Nothing currently '.(a:doyanked ? 'yanked' : 'marked')
		return
	endif
	call sort(l:list, s:sortfunc)

	echo 'Items to cut and paste:'
	echo ' '.join(l:list, "\n ")
	if confirm("Cut and paste?", "&No\n&Yes") < 2
		echo 'Operation canceled'
		return
	endif

	let l:destdir = fnamemodify(s:undercursor(1, line('.') > 3 ? line('.') : 3), ':h')
	let l:destdir = substitute(l:destdir, '/$', '', '').'/'
	let l:destlist = map(copy(l:list), 'l:destdir.fnamemodify(v:val, ":t")')
	call s:renamebylist(l:list, l:destlist)
	call s:refreshtree(0)
endfun  " }}}


fun! s:deletemarked(doyanked, list=0)  " {{{
	if a:doyanked && empty(s:yanked)
		echo 'Nothing currently yanked'
		return
	endif
	let l:list = type(a:list) == v:t_list ? a:list :
	             \(a:doyanked ? s:yanked : b:fm_marked)
	if empty(l:list) && type(a:list) != v:t_list
		if line('.') < 3
			echo 'Not attempting to delete current or parent directory'
			return
		endif
		let l:list = [s:undercursor(0)]
	elseif empty(l:list)
		return
	endif
	call sort(l:list, s:sortfunc)

	" Always faster than two filters
	let l:files = []
	let l:dirs = []
	for l:path in l:list
		call add(getftype(l:path) == 'dir' ? l:dirs : l:files, l:path)
	endfor

	if !empty(l:files)
		echo 'Files to delete:'
		echo ' '.join(l:files, "\n ")
		if confirm("Delete printed files?", "&No\n&Yes") < 2
			echo 'Files not deleted'
		else
			call s:deletelist(l:files, '')
		endif
	endif

	if !empty(l:dirs)
		echo 'Directories to delete:'
		echo ' '.join(l:dirs, "\n ")
		let l:choice = confirm("Delete printed directories?", "&No\n&Empty only\n&All")
		if l:choice < 2
			echo 'Directories not deleted'
		else
			call s:deletelist(l:dirs, l:choice == 2 ? 'd' : 'rf')
		endif
	endif

	let s:yankedtick += len(s:yanked) != len(s:filterexisting(s:yanked))
	let b:fm_markedtick += len(b:fm_marked) != len(s:filterexisting(b:fm_marked))
	" Don't notify if path is not found (deleted)
	silent call s:refreshtree(0)
endfun  " }}}


fun! s:deletelist(list, flag)  " {{{
	" For directories: sort without s:sortfunc here: children first
	for l:path in empty(a:flag) ? a:list : reverse(sort(a:list))
		if delete(l:path, a:flag)
			echohl ErrorMsg
			echomsg 'Failed to delete "'.l:path.'"'
			echohl None
		endif
	endfor
endfun  " }}}


fun! s:renamemarked()  " {{{
	if len(b:fm_marked) > 1
		return s:renametreeprepare()
	endif

	let l:name = empty(b:fm_marked) ? s:undercursor(0) : b:fm_marked[0]
	if l:name[:len(b:fm_treeroot)-1] !=# b:fm_treeroot
		echo 'Unable to rename "'.l:name.'": outside the current tree'
		return
	endif
	exe 'lcd '.fnameescape(fnamemodify(l:name, ':h'))
	echo 'Current name: '.l:name
	call inputsave()
	let l:destination = input('Enter new name: ', fnamemodify(l:name, ':t'), 'file')
	call inputrestore()
	redraw
	if l:destination == ''
		echo 'Empty name supplied. Aborted'
		return
	endif
	let l:substring = matchstr(l:destination, '^\s*\~[^/]*/')
	let l:destination = substitute(l:destination, '^\s*\~[^/]*/', expandcmd(l:substring), '')
	let l:destination = s:simplify(l:destination[0] == '/' ? l:destination
	                               \: substitute(fnamemodify(l:name, ':h'), '/$', '', '').'/'.l:destination)
	let l:err = s:renamebylist([l:name], [l:destination])
	" Probably renaming the file under the cursor
	silent call s:refreshtree(0)
	if !l:err && l:destination[:len(b:fm_treeroot)-1] ==# b:fm_treeroot
		silent call s:movecursorbypath(l:destination)
	endif
endfun  " }}}


fun! s:renametreeprepare()  " {{{
	let l:marked = filter(copy(b:fm_marked), 'v:val[:len(b:fm_treeroot)-1] ==# b:fm_treeroot')
	call map(l:marked, 'v:val[len(b:fm_treeroot):]')
	if empty(l:marked)
		echo 'Nothing marked in current tree'
		return
	endif
	let l:markedtree = {}
	for l:path in l:marked
		let l:dic = l:markedtree
		for l:dir in split(l:path, '/')[:-2]
			if type(get(l:dic, l:dir, 0)) != v:t_dict
				let l:dic[l:dir] = {'': 0}
			endif
			let l:dic = l:dic[l:dir]
		endfor
		call extend(l:dic, {fnamemodify(l:path, ':t'): 0}, 'keep')
	endfor
	call s:renametree(l:markedtree)
endfun  " }}}


fun! s:renametree(tree=0)  " {{{
	if type(a:tree) != v:t_dict && len(b:fm_tree) <= 1
		echo 'Cannot rename empty tree'
		return
	endif
	setl modifiable noreadonly
	call setline(1, "Edit and hit Enter to rename or Esc to abort. Don't reorder lines or change NonText")
	if type(a:tree) == v:t_dict
		silent 3,$delete _
		let l:markedsave = b:fm_marked
		let b:fm_marked = []
		call s:printcontents(a:tree, b:fm_treeroot, 1, 3)
		let b:fm_marked = l:markedsave
		call cursor(3, len(s:depthstr.s:separator) + 1)
	else
		let l:colnr = len(matchstr(getline('.'), '^'.s:depthstrpat.'*'.s:seppat)) + 1
		if l:colnr > col('.')
			call cursor(0, l:colnr)
		endif
	endif

	let b:fm_renamefrom = getline(3, '$')
	call s:setbufname()

	au! filemanager BufEnter,ShellCmdPost <buffer>
	delcommand -buffer Mark
	delcommand -buffer Yank
	delcommand -buffer Filter
	delcommand -buffer GMark
	delcommand -buffer GYank
	delcommand -buffer GFilter
	delcommand -buffer Bookmark
	delcommand -buffer Delbookmark
	mapclear <buffer>
	nnoremap <buffer>  <cr>   <cmd>call <sid>renamefinish(1)<cr>
	inoremap <buffer>  <cr>   <esc><cmd>call <sid>renamefinish(1)<cr>
	nnoremap <buffer>  <esc>  <cmd>call <sid>renamefinish(0)<cr>
	setl undolevels=-123456  " based on :help 'undolevels'
endfun  " }}}


fun! s:renamefinish(do)  " {{{
	if a:do > 0
		if line('$') - 2 != len(b:fm_renamefrom)
			echo 'Number of lines changed. Aborted'
			return s:renamefinish(0)
		endif
		let l:changed = filter(range(3, line('$')), 'b:fm_renamefrom[v:val-3] !=# getline(v:val)')
		if empty(l:changed)
			echo 'Nothing to rename'
			return s:renamefinish(0)
		endif
		let l:renameto = s:undercursorlist(1, copy(l:changed))
		let l:renamefrom = s:undercursorlist(1, l:changed, b:fm_renamefrom, 3)
		call s:renamebylist(l:renamefrom, l:renameto)
	endif

	unlet b:fm_renamefrom
	setl nomodifiable readonly undolevels=-1
	call s:definemapcmdautocmd()
	call s:refreshtree(-1)
endfun  " }}}


fun! s:renamebylist(listfrom, listto)  " {{{
	let l:existing = s:filterexisting(copy(a:listto))
	if !empty(l:existing)
		echo 'Destinations already exist:'
		echo ' '.join(l:existing, "\n ")
		if confirm("Overwrite?", "&No\n&Yes") < 2
			echo 'Nothing moved'
			return 1
		endif
	endif

	let l:success = 0
	for l:i in range(len(a:listfrom))
		if a:listfrom[l:i][-1:-1] == '/'
			echo 'Directory "'.a:listfrom[l:i][:-2].'" is empty'
			continue
		endif
		if rename(a:listfrom[l:i], a:listto[l:i])
			echo 'Failed to move "'.a:listfrom[l:i].'" to "'.a:listto[l:i].'"'
			continue
		endif
		let l:success = 1
		if isdirectory(a:listto[l:i])
			" \= is simpler than doing all the escape() and hope
			let l:subwith = a:listto[l:i].'/'
			call map(a:listfrom, 'v:key <= l:i ? v:val : substitute(v:val, "^\\V".escape(a:listfrom[l:i], "\\")."/", "\\=l:subwith", "")')
			call s:movetreecontents(a:listfrom[l:i], a:listto[l:i])
		endif
	endfor

	let s:yankedtick += len(s:yanked) != len(s:filterexisting(s:yanked))
	let b:fm_markedtick += len(b:fm_marked) != len(s:filterexisting(b:fm_marked))
	return !l:success
endfun  " }}}


fun! s:visualcmd(cmd, ends)  " {{{
	for l:path in uniq(map(filter(range(min(a:ends), max(a:ends)), 'v:val < 3'),
	                      \'s:undercursor(0, v:val)'))
	        echo 'Skipping "'.l:path.'"'
	endfor
	" uniq() for possible empty directories
	let l:list = uniq(s:undercursorlist(0, filter(range(min(a:ends), max(a:ends)), 'v:val > 2')))
	if a:cmd ==# 'y'
		call s:yankmarked(l:list)
	elseif a:cmd ==# 'Y'
		call s:resetyanked(l:list)
	elseif a:cmd ==# 'D'
		call s:deletemarked(0, l:list)
	endif
endfun  " }}}
" }}}


" Buffer configuration {{{
fun! s:cmdlineenter(char)  " {{{
	if &autochdir && a:char == ':' && s:dirreadable(b:fm_treeroot)
		exe 'lcd '.fnameescape(b:fm_treeroot)
	elseif a:char == ':' && haslocaldir(0) == 1
		exe (haslocaldir(-1, 0) ? 'tcd ' : 'cd ' ).fnameescape(getcwd(-1, 0))
	endif
endfun  " }}}


fun! s:processcmdline()  " {{{
	if getcmdtype() != ':' || getcmdline() !~# '<\(yanked\|marked\|cursor\|less\)>'
		return getcmdline()
	endif

	" Should refresh tree only after filtering marked and yanked
	au! filemanager ShellCmdPost <buffer>
	au filemanager ShellCmdPost  <buffer> ++once
	   \ let s:yankedtick += len(s:yanked) != len(s:filterexisting(s:yanked))
	   \ | let b:fm_markedtick += len(b:fm_marked) != len(s:filterexisting(b:fm_marked))
	" Also restores this autocmd from s:definemapcmdautocmd()
	au filemanager ShellCmdPost  <buffer>  call s:refreshtree(-1)

	let l:yankedsh = getcmdline() !~# '<yanked>' || empty(s:yanked) ? '' :
	                 \ join(map(copy(s:yanked), 'shellescape(v:val, 1)'), ' ')
	let l:markedsh = getcmdline() !~# '<marked>' || empty(b:fm_marked) ? '' :
	                 \ join(map(copy(b:fm_marked), 'shellescape(v:val, 1)'), ' ')
	let l:cfile = getcmdline() !~# '<cursor>' ? '' : shellescape(s:undercursor(0), 1)

	let l:split = split(getcmdline(), '<less>', 1)
	call map(l:split, 'split(v:val, "<marked>", 1)')
	" Cannot join here since marked filenames may include <yanked>.
	" Also avoid potential problems with nested v:val usage in map(map()).
	for l:listI in l:split
		call map(l:listI, 'split(v:val, "<yanked>", 1)')
		for l:listII in l:listI
			call map(l:listII, 'split(v:val, "<cursor>", 1)')
			call map(l:listII, 'join(v:val, l:cfile)')
		endfor
		call map(l:listI, 'join(v:val, l:yankedsh)')
	endfor
	call map(l:split, 'join(v:val, l:markedsh)')
	let l:expanded = join(l:split, '<')

	call histadd(':', getcmdline())
	exe 'au filemanager ShellCmdPost  <buffer>  ++once '
	    \.'eval histget(":", -1) ==# '.string(l:expanded).' && histdel(":", -1)'

	return l:expanded
endfun  " }}}


fun! s:checkconfig()  " {{{
	if exists('s:checkconfigdone')
		return
	endif
	let s:checkconfigdone = 1
	let s:sortorder = s:checksortorder(s:sortorder)
	call filter(s:sortrules, 'v:val[:3] == "name" || v:val[:3] == "time"'
	                         \.'|| (v:val[:3] == "obey" && len(v:val) > 5)')
	call filter(s:sortrules, '!s:checkregex(v:key)')
	call map(s:sortrules, '(v:val[0] == "n" && len(v:val) > 5) || v:val[0] == "o" ?'
	                      \.'v:val[:4].s:checksortorder(v:val[5:]) : v:val')
	for l:key in keys(s:sortrules)
		let s:sortrules[s:convertpattern(l:key, 0)] = remove(s:sortrules, l:key)
	endfor
	" Avoid unverified run time changes
	let s:sortrules = copy(s:sortrules)
	echohl ErrorMsg
	if s:winsize < 1 || s:winsize > 99
		echomsg 'Invalid window size "'.s:winsize.'". Variable set to 20'
		let s:winsize = 20
	endif
	if s:skipfilterdirs < 0
		echomsg 'Invalid depth '.s:skipfilterdirs.' of directory '
		        \.'immunity to filters. Variable reset'
		let s:skipfilterdirs = 0
	endif
	if s:ignorecase != '' && s:ignorecase !=# '\c' && s:ignorecase !=# '\C'
		echomsg 'Invalid ignore case option "'.s:ignorecase.'". Variable reset'
		let s:ignorecase = ''
	endif
	if s:sortmethod !=# 'name' && s:sortmethod !=# 'time'
		echomsg 'Invalid sort method "'.s:sortmethod.'". Variable reset'
		let s:sortmethod = 'name'
	endif
	try
		call sort([1, 2], s:sortfunc)
	catch /^Vim\%((\a\+)\)\?:/
		echomsg 'Invalid sort func "'.s:sortfunc.'". Variable reset. '
		        \.substitute(v:exception, '^Vim\%((\a\+)\)\?:', '', '')
		let s:sortfunc = ''
	endtry
	echohl None
endfun  " }}}


fun! s:definemapcmdautocmd()  " {{{
	" Separete function because of s:renametree()
	command! -buffer -bang -nargs=?  Mark         call s:markbypat(<q-args>, <bang>0, 0, 0)
	command! -buffer -bang -nargs=?  Yank         call s:markbypat(<q-args>, <bang>0, 0, 1)
	command! -buffer -bang -nargs=?  Filter       call s:filtercmd(<q-args>, <bang>0, 0)
	command! -buffer -bang -nargs=?  GMark        call s:markbypat(<q-args>, <bang>0, 1, 0)
	command! -buffer -bang -nargs=?  GYank        call s:markbypat(<q-args>, <bang>0, 1, 1)
	command! -buffer -bang -nargs=?  GFilter      call s:filtercmd(<q-args>, <bang>0, 1)
	command! -buffer -bang -nargs=? -complete=customlist,s:bookmarksuggest
	                               \ Bookmark     call s:bookmarkcmd(<bang>0, <q-args>)
	command! -buffer -bang -nargs=? -complete=customlist,s:bookmarkdelsuggest
	                               \ Delbookmark  call s:bookmarkdel(<bang>0, <q-args>)

	" No need for <silent> with <cmd>
	mapclear <buffer>
	nnoremap <nowait> <buffer>  ,        zh
	nnoremap <nowait> <buffer>  .        zl
	nnoremap <nowait> <buffer>  <        zH
	nnoremap <nowait> <buffer>  >        zL
	nnoremap <nowait> <buffer>  f        <cmd>call <sid>openbyname(0)<cr>
	nnoremap <nowait> <buffer>  F        <cmd>call <sid>openbyfind()<cr>
	nnoremap <nowait> <buffer>  d        <cmd>call <sid>newdir()<cr>
	nnoremap <nowait> <buffer>  <cr>     <cmd>call <sid>open(<sid>undercursor(1), 0)<cr>
	nnoremap <nowait> <buffer>  v        <cmd>call <sid>open(<sid>undercursor(1), 1)<cr>
	nnoremap <nowait> <buffer>  o        <cmd>call <sid>open(<sid>undercursor(1), 2)<cr>
	nnoremap <nowait> <buffer>  O        <cmd>call <sid>open(<sid>undercursor(1), 3)<cr>
	nnoremap <nowait> <buffer>  t        <cmd>call <sid>open(<sid>undercursor(1), 4)<cr>
	nnoremap <nowait> <buffer>  s        <cmd>call <sid>open(<sid>undercursor(1), 5)<cr>
	nnoremap <nowait> <buffer>  a        <cmd>call <sid>open(<sid>undercursor(1), 6)<cr>
	nnoremap <nowait> <buffer>  E        <cmd>call <sid>open(<sid>undercursor(1), 7)<cr>
	nnoremap <nowait> <buffer>  T        <cmd>call <sid>openterminal(0)<cr>
	nnoremap <nowait> <buffer>  U        <cmd>call <sid>openterminal(1)<cr>
	nnoremap <nowait> <buffer>  l        <cmd>call <sid>descenddir(<sid>undercursor(1), 1)<cr>
	nnoremap <nowait> <buffer>  <right>  <cmd>call <sid>descenddir(<sid>undercursor(1), 1)<cr>
	nnoremap <nowait> <buffer>  gl       <cmd>call <sid>descenddir(<sid>undercursor(1), 0)<cr>
	nnoremap <nowait> <buffer> <s-right> <cmd>call <sid>descenddir(<sid>undercursor(1), 0)<cr>
	nnoremap <nowait> <buffer>  h        <cmd>call <sid>parentdir()<cr>
	nnoremap <nowait> <buffer>  <left>   <cmd>call <sid>parentdir()<cr>
	nnoremap <nowait> <buffer>  zc       <cmd>call <sid>folddir(<sid>undercursor(1), 0)<cr>
	nnoremap <nowait> <buffer>  zC       <cmd>call <sid>folddir(<sid>undercursor(1), 1)<cr>
	nnoremap <nowait> <buffer>  zm       <cmd>call <sid>foldbydepth(v:count1)<cr>
	nnoremap <nowait> <buffer>  zM       <cmd>call <sid>foldbydepth(-1)<cr>
	nnoremap <nowait> <buffer>  zo       <cmd>call <sid>toggledir(<sid>undercursor(1), 2)<cr>
	nnoremap <nowait> <buffer>  c        <cmd>call <sid>cmdundercursor()<cr>
	nnoremap <nowait> <buffer>  x        <cmd>call <sid>openexternal(<sid>undercursor(1))<cr>
	nnoremap <nowait> <buffer>  X        <cmd>call <sid>openbyname(1)<cr>
	nnoremap <nowait> <buffer>  gs       <cmd>call <sid>statcmd(<sid>undercursor(1))<cr>
	nnoremap <nowait> <buffer>  gf       <cmd>call <sid>filecmd(<sid>undercursor(1))<cr>
	nnoremap <nowait> <buffer>  gr       <cmd>call <sid>togglesortreverse()<cr>
	nnoremap <nowait> <buffer>  gR       <cmd>call <sid>toggleusesortrules()<cr>
	nnoremap <nowait> <buffer>  S        <cmd>call <sid>setsortmethod()<cr>
	nnoremap <nowait> <buffer>  gS       <cmd>call <sid>setsortorder()<cr>
	nnoremap <nowait> <buffer>  gi       <cmd>call <sid>setignorecase()<cr>
	nnoremap <nowait> <buffer>  gh       <cmd>call <sid>toggleshowhidden()<cr>
	nnoremap <nowait> <buffer>  gG       <cmd>call <sid>togglerespectgitignore()<cr>
	nnoremap <nowait> <buffer>  gd       <cmd>call <sid>setskipfilterdirs()<cr>
	nnoremap <nowait> <buffer>  gF       <cmd>call <sid>printfilters()<cr>
	nnoremap <nowait> <buffer>  <c-l>    <cmd>call <sid>refreshtree(0)<cr><c-l>
	nnoremap <nowait> <buffer>  <c-r>    <cmd>call <sid>refreshtree(1)<cr>
	nnoremap <nowait> <buffer>  i        <cmd>call <sid>mark([line('.')])<cr>
	nnoremap <nowait> <buffer>  I        <cmd>call <sid>resetmarked()<cr>
	nnoremap <nowait> <buffer>  r        <cmd>call <sid>renamemarked()<cr>
	nnoremap <nowait> <buffer>  R        <cmd>call <sid>renametree()<cr>
	nnoremap <nowait> <buffer>  D        <cmd>call <sid>deletemarked(0)<cr>
	nnoremap <nowait> <buffer>  <del>    <cmd>call <sid>deletemarked(0)<cr>
	nnoremap <nowait> <buffer>  y        <cmd>call <sid>yankmarked()<cr>
	nnoremap <nowait> <buffer>  Y        <cmd>call <sid>resetyanked()<cr>
	nnoremap <nowait> <buffer>  p        <cmd>call <sid>pastemarked(0, 0)<cr>
	nnoremap <nowait> <buffer>  P        <cmd>call <sid>pastemarked(0, 1)<cr>
	nnoremap <nowait> <buffer>  zp       <cmd>call <sid>pastemarked(1, 0)<cr>
	nnoremap <nowait> <buffer>  zP       <cmd>call <sid>pastemarked(1, 1)<cr>
	nnoremap <nowait> <buffer>  C        <nop>
	nnoremap <nowait> <buffer>  Cp       <cmd>call <sid>movemarked(0)<cr>
	nnoremap <nowait> <buffer>  CP       <cmd>call <sid>movemarked(1)<cr>
	nnoremap <nowait> <buffer>  zD       <cmd>call <sid>deletemarked(1)<cr>
	nnoremap <nowait> <buffer>  <s-del>  <cmd>call <sid>deletemarked(1)<cr>
	nnoremap <nowait> <buffer>  <c-n>    <cmd>call <sid>gotomarked(0)<cr>
	nnoremap <nowait> <buffer>  <c-p>    <cmd>call <sid>gotomarked(1)<cr>
	nnoremap <nowait> <buffer>  b        <nop>
	nnoremap <nowait> <buffer>  B        <nop>
	nnoremap <nowait> <buffer>  b<cr>    <cmd>call <sid>printbookmarks()<cr>
	cnoremap <nowait> <buffer>  <cr>     <c-\>e<sid>processcmdline()<cr><cr>
	xnoremap <nowait> <buffer> <expr>  i    '<esc><cmd>call <sid>mark(['.line('.').', '.line('v').'])<cr>'
	xnoremap <nowait> <buffer> <expr>  y    '<esc><cmd>call <sid>visualcmd("y", ['.line('.').', '.line('v').'])<cr>'
	xnoremap <nowait> <buffer> <expr>  Y    '<esc><cmd>call <sid>visualcmd("Y", ['.line('.').', '.line('v').'])<cr>'
	xnoremap <nowait> <buffer> <expr>  D    '<esc><cmd>call <sid>visualcmd("D", ['.line('.').', '.line('v').'])<cr>'
	xnoremap <nowait> <buffer> <expr> <del> '<esc><cmd>call <sid>visualcmd("D", ['.line('.').', '.line('v').'])<cr>'
	for l:name in s:bookmarknames
		exe 'nnoremap <nowait> <buffer>  B'.l:name.'  <cmd>call <sid>bookmarksave('.string(l:name).', 0)<cr>'
		exe 'nnoremap <nowait> <buffer>  b'.l:name.'  <cmd>call <sid>bookmarkrestore('.string(l:name).')<cr>'
	endfor

	if s:enablemouse
		nmap <nowait> <buffer>  <2-LeftMouse>   <cr>
	endif

	" BufReadCmd needed for when the user runs :edit to reload the buffer
	au! filemanager * <buffer>
	au filemanager BufReadCmd    <buffer>  call s:initialize(b:fm_treeroot, b:fm_auxiliary)
	au filemanager BufEnter      <buffer>  call s:refreshtree(0)
	au filemanager BufUnload     <buffer>  call s:exit(str2nr(expand('<abuf>')))
	au filemanager CmdlineEnter  <buffer>  call s:cmdlineenter(expand('<afile>'))
	au filemanager ShellCmdPost  <buffer>  call s:refreshtree(-1)
endfun  " }}}


fun! s:initialize(path, aux)  " {{{
	" nofile is necessary for independent views of the same directory
	setl bufhidden=wipe buftype=nofile noswapfile
	setl nomodifiable readonly undolevels=-1
	setl nonumber nowrap nofoldenable
	setl conceallevel=3 concealcursor=nc
	setfiletype filemanager

	call s:definemapcmdautocmd()

	for l:var in s:tabvars
		exe 'let b:fm_'.l:var.' = get(t:, "filemanager_".l:var, s:'.l:var.')'
	endfor
	let b:fm_filters = []
	let b:fm_marked = []
	let b:fm_markedtick = 0

	if exists('b:fm_renamefrom')
		unlet b:fm_renamefrom
	endif

	let b:fm_treeroot = substitute(a:path, '/$', '', '').'/'
	let b:fm_tree = s:getdircontents(b:fm_treeroot)

	let b:fm_auxiliary = a:aux
	if b:fm_auxiliary
		call add(s:buflist, bufnr())
	else
		call insert(s:buflist, bufnr())
	endif

	if s:alwaysfixwinsize && !b:fm_auxiliary
		let &winfixwidth = b:fm_vertical
		let &winfixheight = !b:fm_vertical
	endif

	call s:printtree(0)
	call cursor(2, 1)
endfun  " }}}


fun! s:getbufnr()  " {{{
	let l:list = filter(copy(s:buflist), 'index(tabpagebuflist(), v:val) != -1')
	return empty(l:list) ? -1 : l:list[0]
endfun  " }}}


fun! s:spawn(dir, bang, count, vertical)  " {{{
	let l:bufnr = s:getbufnr()
	if a:bang && a:dir == ''
		if l:bufnr == -1
			echo 'No filemanager open in current tab'
		else
			if len(getbufinfo({'buflisted': 1})) == 1
				echo 'Already last buffer'
			else
				exe l:bufnr.'bdelete'
			endif
		endif
		return
	endif

	if a:dir == ''
		let l:dir = ''
	elseif isdirectory(a:dir)
		let l:dir = fnameescape(a:dir)
	else
		echo 'Ignoring "'.a:dir.'": not a directory'
		let l:dir = ''
	endif

	if l:bufnr == -1
		exe 'new '.(l:dir == '' ? '.' : l:dir)
		let l:bufnr = bufnr()
	elseif l:dir != '' && a:bang
		exe bufwinnr(l:bufnr).'wincmd w'
		exe 'edit '.l:dir
		let l:bufnr = bufnr()
	elseif l:dir != ''
		echo 'Ignoring command argument'
	endif

	if a:count < 0 || a:count > 100
		echo 'Window size must lie between 0 and 100'
	elseif a:count
		call setbufvar(l:bufnr, 'fm_winsize', a:count)
	endif
	call setbufvar(l:bufnr, 'fm_vertical', a:vertical)
	call win_execute(bufwinid(l:bufnr), 'call s:spawn_resizewin()')
	wincmd =  " sizes are messed up after wincmd HJKL
endfun  " }}}


fun! s:spawn_resizewin()  " {{{
	if b:fm_vertical
		exe 'wincmd '.(s:preferleft ? 'H' : 'L')
		exe 'vertical resize '.(b:fm_winsize * &columns / 100)
		resize
	else
		exe 'wincmd '.(s:preferbelow ? 'J' : 'K')
		exe 'resize '.(b:fm_winsize * &lines / 100)
		if winnr('$') == 1
			resize
		endif
	endif
	let &winfixwidth = b:fm_vertical
	let &winfixheight = !b:fm_vertical
	if b:fm_auxiliary
		let b:fm_auxiliary = 0
		if s:settabdir && s:dirreadable(b:fm_treeroot)
			exe 'tcd '.fnameescape(b:fm_treeroot)
		endif
		call s:setbufname()
	endif
endfun  " }}}


fun! s:enter(path, bufnr)  " {{{
	if !isdirectory(a:path) || !v:vim_did_enter || exists('b:fm_auxiliary')
		return
	endif
	" Don't bother calling anything if already initialized

	call s:checkconfig()
	call s:initialize(simplify(a:path), s:getbufnr() != -1)
endfun  " }}}


fun! s:exit(bufnr)  " {{{
	call remove(s:buflist, index(s:buflist, a:bufnr))
	if getbufvar(a:bufnr, 'fm_auxiliary')
		return
	endif
	" Attempt to save config for all relevant tabs, but actually BufUnload
	" is triggered only when the last window (hence in last tab) is closed.
	for l:tabnr in filter(range(1, tabpagenr('$')), 'index(tabpagebuflist(v:val), a:bufnr) != -1')
		for l:var in s:tabvars
			call settabvar(l:tabnr, 'filemanager_'.l:var, getbufvar(a:bufnr, 'fm_'.l:var))
		endfor
	endfor
	if s:bookmarkonbufexit
		call s:bookmarkbackup(a:bufnr)
	endif
	" The autocmds and variables are unset by vim (bufhidden=wipe)
endfun  " }}}
" }}}
