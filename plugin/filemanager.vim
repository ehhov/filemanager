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
let s:filterdirs           = get(g:, 'filemanager_filterdirs',           1)
let s:resetmarkedonsuccess = get(g:, 'filemanager_resetmarkedonsuccess', 1)
let s:showhidden           = get(g:, 'filemanager_showhidden',           1)
let s:respectgitignore     = get(g:, 'filemanager_respectgitignore',     1)
let s:respectwildignore    = get(g:, 'filemanager_respectwildignore',    0)
let s:ignorecase           = get(g:, 'filemanager_ignorecase',          '')
let s:sortmethod           = get(g:, 'filemanager_sortmethod',      'name')
let s:sortfunc             = get(g:, 'filemanager_sortfunc',            '')
let s:sortorder = get(g:, 'filemanager_sortorder', '/$,.*[^/]$,^\..*/$,^\..*[^/]$,\.bak$,^__pycache__/$,\.swp$,\~$')
let s:depthstr = '| '
let s:depthstrmarked = '|+'
let s:depthstryanked = '|-'
let s:separator = "'"  " separates depth and file type from file name
let s:seppat = "'"     " in case separator is a special character


" Just <abuf> doesn't work. More autocmds in s:initialize() and elsewhere
aug filemanager
	au!
	au VimEnter           *  silent! au! FileExplorer
	au VimEnter,BufEnter  *  call s:enter(expand('<afile>:p'), str2nr(expand('<abuf>')))
	if s:usebookmarkfile
		au VimEnter   *  silent call s:loadbookmarks()
		au VimLeave   *  call s:writebookmarks(0)
	endif
aug END


" Use the longer representation if your depthstr's have special characters
"let s:depthstrpat = '\(\V'.escape(s:depthstr, '\').'\m\|\V'.escape(s:depthstrmarked, '\').'\m\)'
let s:depthstrpat = '\('.s:depthstr.'\|'.s:depthstrmarked.'\|'.s:depthstryanked.'\)'
let s:depthstronlypat = '\('.s:depthstr.'\)'
let s:depthstrmarkedpat = '\('.s:depthstrmarked.'\)'
let s:depthstryankedpat = '\('.s:depthstryanked.'\)'
let s:filetypepat = '\%([\*@=|/]\|!@\|\)'

let s:tabvars = ['sortorder', 'sortmethod', 'sortreverse', 'ignorecase', 'filterdirs',
                \'respectgitignore', 'showhidden', 'vertical', 'winsize']
let s:sortreverse = 0  " for uniformity in s:initialize() and s:exit()

" Required to be able to move filemanager windows between tabs
let s:buflist = []

" Script-wide marked items: yanked
let s:yanked = []
let s:yankedtick = 0
let s:yankedsh = ''
let s:yankedshtick = 0

let s:bookmarks = {}
let s:bookmarkvars = ['treeroot', 'filters', 'marked'] + s:tabvars
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
fun! s:dirreadable(path)  " {{{
	return isdirectory(a:path) && !empty(glob(escape(fnameescape(a:path), '~').'/.', 1, 1, 1))
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
	let l:list = glob(l:path.'/*', !s:respectwildignore, 1, 1)
	if b:fm_showhidden
		let l:list += glob(l:path.'/.*', !s:respectwildignore, 1, 1)
	endif
	for l:item in l:list
		if isdirectory(l:item)
			let l:dic[fnamemodify(l:item, ':t')] = {}
		else
			let l:dic[fnamemodify(l:item, ':t')] = 0
		endif
	endfor
	" This was measured to be (slightly) faster at any length of l:ignored
	for l:ex in l:ignored
		if has_key(l:dic, l:ex)
			call remove(l:dic, l:ex)
		endif
	endfor
	return l:dic
endfun  " }}}


fun! s:sortbyname(list, path)  " {{{
	let l:revsplitsortorder = reverse(split(b:fm_sortorder, '[^\\]\zs,'))
	call map(l:revsplitsortorder, 'substitute(v:val, "\\\\,", ",", "g")')
	let l:matches = add(map(copy(l:revsplitsortorder), '[]'), [])

	for l:name in a:list
		if getftype(a:path.'/'.l:name) == 'dir'
			let l:line = l:name.'/'  " No separator here
		else
			let l:line = l:name
		endif
		let l:i = 0
		for l:pattern in l:revsplitsortorder
			if match(l:line, '\C'.l:pattern) != -1
				let l:i = -l:i - 1
				break
			endif
			let l:i += 1
		endfor
		call add(l:matches[l:i < 0 ? -l:i : 0], l:name)
	endfor

	let l:sorted = []
	for l:sublist in reverse(l:matches)
		let l:sorted += sort(l:sublist, s:sortfunc)
	endfor

	return l:sorted
endfun  " }}}


fun! s:sortbytime(list, path)  " {{{
	let l:list = map(a:list, 'getftime(a:path."/".v:val)." ".v:val')
	return map(reverse(sort(l:list, 'N')), 'substitute(v:val, "^-\\?\\d* ", "", "")')
endfun  " }}}


fun! s:sort(dic, path)  " {{{
	if b:fm_sortmethod == 'name'
		let l:sorted = s:sortbyname(keys(a:dic), a:path)
	elseif b:fm_sortmethod == 'time'
		let l:sorted = s:sortbytime(keys(a:dic), a:path)
	endif
	return b:fm_sortreverse ? reverse(l:sorted) : l:sorted
endfun  " }}}


fun! s:printcontents(dic, path, depth, linenr)  " {{{
	let l:path = substitute(a:path, '/$', '', '')
	let l:linenr = a:linenr

	for l:name in s:sort(a:dic, l:path)
		let l:ftype = getftype(l:path.'/'.l:name)
		if l:name == ''
			" This is where timestamps are stored
			if len(a:dic) > 1
				continue
			endif
			" Directory was empty
			let l:line = s:separator
		elseif l:ftype == 'dir'
			let l:line = l:name.s:separator.'/'
		elseif l:ftype == 'link' && empty(glob(escape(fnameescape(l:path.'/'.l:name), '~'), 1, 1, 0))
			let l:line = l:name.s:separator.'!@'
		elseif l:ftype == 'link'
			let l:line = l:name.s:separator.'@'
		elseif l:ftype == 'socket'
			let l:line = l:name.s:separator.'='
		elseif l:ftype == 'fifo'
			let l:line = l:name.s:separator.'|'
		elseif executable(l:path.'/'.l:name)
			let l:line = l:name.s:separator.'*'
		else
			let l:line = l:name.s:separator
		endif

		if index(b:fm_marked, l:path.'/'.l:name) != -1
			let l:line = repeat(s:depthstrmarked, a:depth).s:separator.l:line
		elseif index(s:yanked, l:path.'/'.l:name) != -1
			let l:line = repeat(s:depthstryanked, a:depth).s:separator.l:line
		else
			let l:line = repeat(s:depthstr, a:depth).s:separator.l:line
		endif

		call setline(l:linenr, l:line)
		let l:linenr += 1

		let l:contents = a:dic[l:name]
		if type(l:contents) == v:t_dict && !empty(l:contents)
			let l:linenr = s:printcontents(l:contents, l:path.'/'.l:name, a:depth+1, l:linenr)
		endif
	endfor

	return l:linenr
endfun  " }}}


fun! s:filtercontents(dic, relpath)  " {{{
	let l:filtered = {}
	for [l:name, l:contents] in items(a:dic)
		if type(l:contents) == v:t_dict && !empty(l:contents)
			let l:contents = s:filtercontents(l:contents, a:relpath.l:name.'/')
			" No need to check if name matches when contents do
			if len(l:contents) > 1
				let l:filtered[l:name] = l:contents
				continue
			endif
		endif
		if l:name == '' || (!b:fm_filterdirs && type(l:contents) == v:t_dict)
			let l:filtered[l:name] = l:contents
			continue
		endif
		let l:all = 1
		for l:pattern in b:fm_filters
			if (l:pattern[0] !=# '!') == (match(a:relpath.l:name, b:fm_ignorecase.l:pattern[1:]) == -1)
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
	silent exe 'file '.fnameescape(l:str.' '.substitute(b:fm_treeroot, '/$', '', '').'/')
endfun  " }}}


fun! s:printtree()  " {{{
	let b:fm_yankedticksave = s:yankedtick
	let b:fm_markedticksave = b:fm_markedtick
	setl modifiable noreadonly
	silent %delete _
	call setline(1, '..'.s:separator.'/')
	call setline(2, fnamemodify(b:fm_treeroot, ':t').s:separator.'/')
	if empty(b:fm_filters)
		call s:printcontents(b:fm_tree, b:fm_treeroot, 1, 3)
	else
		call s:printcontents(s:filtercontents(b:fm_tree, ''), b:fm_treeroot, 1, 3)
	endif
	setl nomodifiable readonly nomodified
	if !b:fm_auxiliary
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
endfun  " }}}


fun! s:undercursor(keeptrailslash, linenr=-1, lines=0)  " {{{
	let l:linenr = a:linenr < 0 ? line('.') : a:linenr

	if l:linenr == 1 && type(a:lines) != v:t_list
		return fnamemodify(b:fm_treeroot, ':h')
	elseif l:linenr == 2 && type(a:lines) != v:t_list
		return b:fm_treeroot
	endif

	let l:line = type(a:lines) == v:t_list ? a:lines[l:linenr] : getline(l:linenr)
	let l:nodepth = substitute(l:line, '^'.s:depthstrpat.'*'.s:seppat, '', '')
	let l:path = [substitute(l:nodepth, s:seppat.s:filetypepat.'$', '', '')]
	let l:depth = len(l:line) - len(l:nodepth)
	if !a:keeptrailslash && l:path[0] == ''
		call remove(l:path, 0)
	endif

	while l:depth > len(s:depthstr.s:separator)
		let l:linenr -= 1
		let l:line = type(a:lines) == v:t_list ? a:lines[l:linenr] : getline(l:linenr)
		let l:nodepth = substitute(l:line, '^'.s:depthstrpat.'*'.s:seppat, '', '')
		let l:otherdepth = len(l:line) - len(l:nodepth)

		if l:depth > l:otherdepth
			call insert(l:path, substitute(l:nodepth, s:seppat.s:filetypepat.'$', '', ''))
			let l:depth = l:otherdepth
		endif
	endwhile

	return substitute(b:fm_treeroot, '/$', '', '').'/'.join(l:path, '/')
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
			let l:line = getline(l:linenr)
			if match(l:line, '\C^'.s:depthstrpat.'\{'.l:depth.'}'.s:seppat.'\V'.escape(l:name, '\').'\m'.s:seppat.s:filetypepat.'$') != -1
				break
			endif
			let l:linenr += 1
			if match(l:line, '\C^'.s:depthstrpat.'\{'.l:depth.'}') == -1 || l:linenr > l:lastnr
				echo 'Path not visible or non-existent: "'.a:path.'"'
				return 1
			endif
		endwhile
	endfor
	let l:linenr += (a:path[-1:-1] == '/')
	call cursor(l:linenr, 0)
	return 0
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
		let l:winview = winsaveview()
		call s:printtree()
		call winrestview(l:winview)
	endif
	return 0
endfun  " }}}


fun! s:folddir(path, recursively)  " {{{
	if a:recursively
		let l:path = split(a:path[len(b:fm_treeroot):], '/')
		if len(l:path) < 2
			let l:path = b:fm_treeroot
		else
			let l:path = b:fm_treeroot.'/'.l:path[0]
		endif
	else
		let l:path = fnamemodify(a:path, ':h')
	endif
	if !s:toggledir(l:path, 1)
		call s:movecursorbypath(l:path)
	endif
endfun  " }}}


fun! s:descenddir(path, onlyone)  " {{{
	let l:cmp = substitute(b:fm_treeroot, '/$', '', '').'/'
	if a:path[:len(l:cmp)-1] !=# l:cmp && a:path !=# b:fm_treeroot
	   \ && a:path !=# fnamemodify(b:fm_treeroot, ':h')
		" Happens when the user tries to s:openbyname() by abs. path
		echo 'Directory out of reach: "'.a:path.'"'
		return
	endif
	let l:list = split(a:path[len(b:fm_treeroot):], '/')
	if empty(l:list)
		echo 'Unable to descend upwards'
		return
	endif
	if !isdirectory(a:path)
		call remove(l:list, -1)
	endif
	if empty(l:list)
		echo 'Nowhere to descend'
		return
	endif
	if a:onlyone
		let l:list = l:list[0:0]
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
	let b:fm_treeroot = substitute(b:fm_treeroot, '/$', '', '').'/'.join(l:list, '/')
	if empty(b:fm_tree)
		let b:fm_tree = s:getdircontents(b:fm_treeroot)
	endif

	let l:winview = winsaveview()
	call s:printtree()
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
	let newroot = fnamemodify(b:fm_treeroot, ':h')
	if b:fm_treeroot ==# l:newroot
		echo 'Already in the uppermost directory'
		return
	endif
	let l:setcol = line('.') > 2
	let l:path = s:undercursor(1, line('.') > 2 ? line('.') : 2)
	let l:oldtree = b:fm_tree
	let l:oldrootname = fnamemodify(b:fm_treeroot, ':t')
	let b:fm_treeroot = l:newroot
	let b:fm_tree = s:getdircontents(b:fm_treeroot)
	if type(get(b:fm_tree, l:oldrootname, 0)) == v:t_dict
		let b:fm_tree[l:oldrootname] = l:oldtree
	endif
	let l:winview = winsaveview()
	call s:printtree()
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
				let [l:updated, a:dic[l:name]] = s:refreshcontents(l:contents, a:path.'/'.l:name, a:force)
				if l:updated
					let l:anyupdated = 1
				endif
			endif
		endfor
		return [l:anyupdated, a:dic]
	endif
	let l:newtree = s:getdircontents(a:path)
	for l:name in keys(l:newtree)
		let l:contents = get(a:dic, l:name, 0)
		if type(l:contents) == v:t_dict && !empty(l:contents)
			let l:newtree[l:name] = s:refreshcontents(l:contents, a:path.'/'.l:name, a:force)[1]
		endif
	endfor
	return [1, l:newtree]
endfun  " }}}


fun! s:refreshtree(force)  " {{{
	let l:refreshed = s:refreshcontents(b:fm_tree, b:fm_treeroot, a:force > 0)
	if l:refreshed[0] == 0
		if a:force < 0 || b:fm_yankedticksave < s:yankedtick
		   \ || b:fm_markedticksave < b:fm_markedtick
			let l:winview = winsaveview()
			call s:printtree()
			call winrestview(l:winview)
		endif
		return
	endif
	" simplify() required only after renaming by tree
	let l:path = s:simplify(s:undercursor(1))
	let b:fm_tree = l:refreshed[1]
	let l:winview = winsaveview()
	call s:printtree()
	call winrestview(l:winview)
	let l:cmp = substitute(b:fm_treeroot, '/$', '', '').'/'
	if l:path[:len(l:cmp)-1] ==# l:cmp
		call s:movecursorbypath(l:path)
	endif
endfun  " }}}


fun! s:movetreecontents(from, to)  " {{{
	let l:to = s:simplify(a:to)
	let l:cmp = substitute(b:fm_treeroot, '/$', '', '').'/'
	if l:to[:len(l:cmp)-1] !=# l:cmp
		return
	endif
	let l:dicfrom = b:fm_tree
	let l:split = split(a:from[len(b:fm_treeroot):], '/')
	for l:name in l:split[:-2]
		let l:dicfrom = l:dicfrom[l:name]
	endfor
	let l:namefrom = l:split[-1]
	let l:dicto = b:fm_tree
	let l:split = split(l:to[len(b:fm_treeroot):], '/')
	for l:name in l:split[:-2]
		if !has_key(l:dicto, l:name)
			return
		endif
		let l:dicto = l:dicto[l:name]
	endfor
	let l:dicto[l:split[-1]] = remove(l:dicfrom, l:namefrom)
endfun  " }}}


fun! s:toggleshowhidden()  " {{{
	let b:fm_showhidden = !b:fm_showhidden
	call s:refreshtree(1)
	echo 'Show hidden '.(b:fm_showhidden ? 'ON' : 'OFF')
endfun  " }}}


fun! s:setignorecase()  " {{{
	let l:choice = confirm("Configure ignore case in Filter and Mark:", "&Obey 'ignorecase'\n&Ignore\n&Don't ignore")
	if l:choice == 0
		return
	else
		let b:fm_ignorecase = ['', '\c', '\C'][l:choice-1]
	endif
	let l:path = s:undercursor(1)
	let l:winview = winsaveview()
	call s:printtree()
	call winrestview(l:winview)
	call s:movecursorbypath(l:path)
endfun  " }}}


fun! s:togglerespectgitignore()  " {{{
	let b:fm_respectgitignore = !b:fm_respectgitignore
	call s:refreshtree(1)
	echo 'Respect .gitignore '.(b:fm_respectgitignore ? 'ON' : 'OFF')
endfun  " }}}


fun! s:togglefilterdirs()  " {{{
	let b:fm_filterdirs = !b:fm_filterdirs
	let l:path = s:undercursor(1)
	let l:winview = winsaveview()
	call s:printtree()
	call winrestview(l:winview)
	call s:movecursorbypath(l:path)
	echo 'Filter directories '.(b:fm_filterdirs ? 'ON' : 'OFF')
endfun  " }}}


fun! s:togglesortreverse()  " {{{
	let b:fm_sortreverse = !b:fm_sortreverse
	let l:path = s:undercursor(1)
	let l:winview = winsaveview()
	call s:printtree()
	call winrestview(l:winview)
	call s:movecursorbypath(l:path)
	echo 'Reverse sort order '.(b:fm_sortreverse ? 'ON' : 'OFF')
endfun  " }}}


fun! s:setsortmethod()  " {{{
	let l:choice = confirm("Set sort method:", "By &name\nBy &time")
	if l:choice == 0
		return
	else
		let b:fm_sortmethod = ['name', 'time'][l:choice-1]
	endif
	let l:path = s:undercursor(1)
	let l:winview = winsaveview()
	call s:printtree()
	call winrestview(l:winview)
	call s:movecursorbypath(l:path)
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
	let l:path = s:undercursor(1)
	let l:winview = winsaveview()
	call s:printtree()
	call winrestview(l:winview)
	call s:movecursorbypath(l:path)
endfun  " }}}


fun! s:checksortorder(sortorder)  " {{{
	let l:validsortorder = []
	for l:pattern in split(a:sortorder, '[^\\]\zs,')
		if !s:checkregex(substitute(l:pattern, '\\,', ',', 'g'))
			call add(l:validsortorder, l:pattern)
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


fun! s:filtercmd(pattern, bang)  " {{{
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
		if s:checkregex(a:pattern)
			return
		endif
		call add(b:fm_filters, (a:bang ? '!' : ' ') . a:pattern . (a:pattern[-1:-1] == '$' ? '' : '[^/]*$'))
	endif

	call s:printtree()
	call cursor(2, 1)
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
	for l:name in s:sort(a:tree, b:fm_treeroot.'/'.a:relpath)
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
		let s:bookmarks[a:name][0] = 0
	else
		" string() needed since marked and filters are lists
		let s:bookmarks[a:name] = map(copy(s:bookmarkvars), 'string(eval("b:fm_".v:val))')
		call insert(s:bookmarks[a:name], s:opendirs(b:fm_tree, ''))
		call insert(s:bookmarks[a:name], s:undercursor(1))
		call insert(s:bookmarks[a:name], a:bak)
		let b:fm_changedticksave = b:changedtick
		if !a:bak
			echomsg 'Bookmark "'.a:name.'" saved'
		endif
	endif
endfun  " }}}


fun! s:bookmarkbackup(bufnr)  " {{{
	if exists('b:fm_changedticksave') && b:fm_changedticksave == b:changedtick
		return
	endif
	let l:shift = []
	for l:name in s:bookmarknames
		if has_key(s:bookmarks, l:name)
			if s:bookmarks[l:name][0]
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
	let l:i = 3
	for l:var in s:bookmarkvars
		exe 'let b:fm_'.l:var.' = '.l:bookmark[l:i]
		let l:i += 1
	endfor
	let b:fm_markedtick += 1  " since marked is also restored
	let b:fm_tree = s:getdircontents(b:fm_treeroot)
	for l:path in l:bookmark[2]
		call s:toggledir(b:fm_treeroot.'/'.l:path, 2, 1)
	endfor
	call s:printtree()
	if s:movecursorbypath(l:bookmark[1])
		call cursor(2, 1)
	endif
	let b:fm_changedticksave = b:changedtick
	echomsg 'Bookmark "'.a:name.'" restored'
endfun  " }}}


fun! s:printbookmarks()  " {{{
	if empty(s:bookmarks)
		echo 'No bookmarks saved'
		return
	endif
	echo 'Bookmarks:'
	let l:i = index(s:bookmarkvars, 'treeroot') + 3
	for l:name in sort(filter(keys(s:bookmarks), 'index(s:bookmarknames, v:val) == -1'), s:sortfunc)
	          \ + filter(copy(s:bookmarknames), 'has_key(s:bookmarks, v:val) && !s:bookmarks[v:val][0]')
	          \ + filter(copy(s:bookmarknames), 'has_key(s:bookmarks, v:val) && s:bookmarks[v:val][0]')
		let l:prepend = (s:bookmarks[l:name][0] ? 'bak ' : '').l:name.': '
		echo l:prepend.s:bookmarks[l:name][l:i]
		if !empty(s:bookmarks[l:name][2])
			let l:indent = repeat(' ', len(l:prepend)+2)
			echo l:indent.join(s:bookmarks[l:name][2], "\n".l:indent)
		endif
	endfor
endfun  " }}}


fun! s:writebookmarks(overwrite)  " {{{
	if s:writebackupbookmarks && s:writeshortbookmarks
		let l:bookmarks = s:bookmarks
	elseif s:writeshortbookmarks
		let l:bookmarks = filter(copy(s:bookmarks), '!v:val[0]')
	else
		let l:bookmarks = filter(copy(s:bookmarks), 'index(s:bookmarknames, v:val) == -1')
	endif
	if !a:overwrite && filereadable(s:bookmarkfile)
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
	if writefile([string(l:saved)], s:bookmarkfile)
		echohl ErrorMsg
		echomsg 'Failed to write bookmarks to file'
		echohl None
		return 1
	endif
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
			call extend(s:bookmarks, eval(l:saved[0]))
		endif
	endif
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
	if empty(s:bookmarks)
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
	let l:list = sort(filter(keys(s:bookmarks), 'index(s:bookmarknames, v:val) == -1'), s:sortfunc)
	          \ + filter(copy(s:bookmarknames), 'has_key(s:bookmarks, v:val) && !s:bookmarks[v:val][0]')
	          \ + filter(copy(s:bookmarknames), 'has_key(s:bookmarks, v:val) && s:bookmarks[v:val][0]')
	if !empty(a:arglead)
		call filter(l:list, 'v:val[:len(a:arglead)-1] == a:arglead')
	endif
	return l:list
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
		if empty(glob(escape(fnameescape(s:bookmarkfile), '~'), 1, 1, 1))
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
		if empty(s:bookmarks)
			echo 'No bookmarks saved'
		elseif confirm("Delete all bookmarks?", "&No\n&Yes") == 2
			call filter(s:bookmarks, 0)
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

	let l:path = s:simplify(substitute(l:path, '/$', '', '').'/'.l:name)
	if !empty(glob(escape(fnameescape(l:path), '~'), 1, 1, 1))
		echo 'Path exists: "'.l:path.'"'
		return
	endif

	let l:cmp = b:fm_treeroot == '/' ? '/' : b:fm_treeroot.'/'
	let l:outside = l:path[:len(l:cmp)-1] !=# l:cmp
	if l:outside
		if confirm("Create directory outside the current tree?", "&No\n&Yes") < 2
			return
		endif
	endif
	try
		call mkdir(l:path)
	catch /^Vim\%((\a\+)\)\?:E739/
		echo 'Failed to create directory "'.l:path.'"'
		return
	endtry
	if l:outside
		return
	endif
	let l:name = l:path[len(l:cmp):]
	let l:path = l:cmp
	call s:refreshtree(0)
	for l:dir in split(l:name, '/')
		" Don't notify if already open
		silent call s:toggledir(l:path.l:dir, 2)
		let l:path .= l:dir.'/'
	endfor
	call s:movecursorbypath(l:path)
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
	let l:autochdirsave = &autochdir
	set noautochdir
	if b:fm_auxiliary
		let l:cleanupcode = ''
	else
		if winnr('#') == 0 || winnr('#') == winnr()
			if b:fm_vertical
				silent new
				exe 'wincmd '.(s:preferleft ? 'L' : 'H')
				exe 'vertical resize '.((100 - l:winsize) * &columns / 100)
			else
				silent new
				exe 'wincmd '.(s:preferbelow ? 'K' : 'J')
				exe 'resize '.((100 - l:winsize) * &lines / 100)
			endif
			let l:cleanupcode = 'silent close'
		else
			silent wincmd p
			let l:cleanupcode = 'silent wincmd p'
		endif
	endif

	try
		exe 'confirm '.v:count.'find '.fnameescape(l:name)
	catch /^Vim(find):/
		exe l:cleanupcode
		let &autochdir = l:autochdirsave
		echohl ErrorMsg
		" Remove the leading Vim(find):
		echomsg v:exception[10:]
		echohl None
	endtry
	let &autochdir = l:autochdirsave
endfun  " }}}


fun! s:openbyname()  " {{{
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
	if l:name[0] != '/'
		let l:name = substitute(l:path, '/$', '', '').'/'.l:name
	endif

	call s:open(s:simplify(l:name), -1)
endfun  " }}}


fun! s:open(path, mode)  " {{{
	if isdirectory(a:path)
		if a:mode == 0
			call s:toggledir(a:path, 0)
			return
		elseif a:mode == -1
			call s:descenddir(a:path, 0)
			return
		elseif a:mode == 4
			" Allow opening in a new tab
		else
			echo '"'.a:path.'" is a directory'
			return
		endif
	" Don't list missing symlinks, otherwise they are always not readable
	elseif !empty(glob(escape(fnameescape(a:path), '~'), 1, 1, 0)) && !filereadable(a:path)
		echo '"'.a:path.'" is not readable'
		return
	endif

	if b:fm_auxiliary
		exe 'edit '.fnameescape(a:path)
		return
	endif

	let l:winsize = b:fm_winsize

	if a:mode == 0 || a:mode == -1  " <enter> or by name
		if winnr('#') == 0 || winnr('#') == winnr()
			call s:open(a:path, b:fm_vertical ? 1 : 2)
			return
		endif
		silent wincmd p
		exe 'confirm edit '.fnameescape(a:path)
	elseif a:mode == 1  " single vertical window
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
		exe 'new '.fnameescape(a:path)
		exe 'wincmd '.(s:preferleft ? 'L' : 'H')
		exe 'vertical resize '.((100 - l:winsize) * &columns / 100)
	elseif a:mode == 2  " single horizontal window
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
		exe 'new '.fnameescape(a:path)
		exe 'wincmd '.(s:preferbelow ? 'K' : 'J')
		exe 'resize '.((100 - l:winsize) * &lines / 100)
	elseif a:mode == 3  " above/below all and maximized
		exe 'new '.fnameescape(a:path)
		exe 'wincmd '.(s:preferbelow ? 'K' : 'J')
		resize
	elseif a:mode == 4  " new tab
		exe 'tab new '.fnameescape(a:path)
	elseif a:mode == 5  " new split on the side
		let l:winview = winsaveview()
		exe 'new '.fnameescape(a:path)
		exe 'wincmd '.(s:preferbelow ? 'K' : 'J')
		" :noautocmd should be safe when only resizing and returning
		noautocmd silent wincmd p
		exe 'wincmd '.(s:preferleft ? 'H' : 'L')
		exe 'vertical resize '.(l:winsize * &columns / 100)
		call winrestview(l:winview)
		noautocmd silent wincmd p
		wincmd =
	elseif a:mode == 6  " replace filemanager window
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
	let l:cdcmd = s:dirreadable(l:path) ? 'tcd '.fnameescape(l:path) : ''
	let l:cdback = s:dirreadable(l:path) ? 'tcd '.fnameescape(getcwd(-1, 0)) : ''

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
	for [l:name, l:contents] in items(filter(copy(a:tree), 'v:key != ""'))
		if match(a:relpath.l:name, b:fm_ignorecase.a:pattern) != -1
			call add(l:list, a:relpath.l:name)
		endif
		if type(l:contents) == v:t_dict && !empty(l:contents)
			let l:list += s:namematches(l:contents, a:relpath.l:name.'/', a:pattern)
		endif
	endfor
	return l:list
endfun  " }}}


fun! s:markbypat(pattern, bang)  " {{{
	if s:checkregex(a:pattern)
		return
	endif
	let l:cmp = b:fm_treeroot == '/' ? '/' : b:fm_treeroot.'/'
	let l:pattern = a:pattern . (a:pattern[-1:-1] == '$' ? '' : '[^/]*$')
	if a:bang
		let l:i = -1
		for l:path in b:fm_marked
			let l:i += 1
			if l:path[:len(l:cmp)-1] !=# l:cmp
				echo 'Ignoring "'.l:path.'"'
				continue
			endif
			if match(l:path[len(l:cmp):], b:fm_ignorecase.l:pattern) != -1
				call remove(b:fm_marked, l:i)
				let l:i -= 1
			endif
		endfor
	else
		let l:list = s:namematches(b:fm_tree, '', l:pattern)
		call uniq(sort(extend(b:fm_marked, map(l:list, 'l:cmp.v:val'))))
	endif
	let b:fm_markedtick += 1
	let l:winview = winsaveview()
	call s:printtree()
	call winrestview(l:winview)
endfun  " }}}


fun! s:mark(rangeends)  " {{{
	let l:oldlen = len(b:fm_marked)
	let l:presentpaths = []
	let l:newpaths = []
	for l:linenr in range(min(a:rangeends), max(a:rangeends))
		let l:path = s:undercursor(0, l:linenr)
		if l:linenr < 3
			echo 'Skipping "'.l:path.'"'
			continue
		endif
		let l:i = index(b:fm_marked, l:path)
		if l:i == -1
			call add(l:newpaths, l:path)
		else
			call add(l:presentpaths, l:i)
		endif
	endfor
	if empty(l:newpaths)
		for l:i in reverse(sort(l:presentpaths, 'n'))
			call remove(b:fm_marked, l:i)
		endfor
	else
		let b:fm_marked += l:newpaths
	endif
	if len(b:fm_marked) != l:oldlen
		let b:fm_markedtick += 1
		let l:winview = winsaveview()
		call s:printtree()
		call winrestview(l:winview)
	endif
endfun  " }}}


fun! s:resetmarked()  " {{{
	if !empty(b:fm_marked)
		let b:fm_markedtick += 1
		call filter(b:fm_marked, 0)
		let l:winview = winsaveview()
		call s:printtree()
		call winrestview(l:winview)
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
		echo 'Yanked list extended by '.(len(s:yanked) - l:oldlen).' (from '.l:oldlen.' to '.len(s:yanked).')'
		let s:yankedtick += 1
	endif
	if type(a:list) != v:t_list
		call filter(b:fm_marked, 0)
		let b:fm_markedtick += 1
	elseif len(s:yanked) == l:oldlen
		return
	endif
	let l:winview = winsaveview()
	call s:printtree()
	call winrestview(l:winview)
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
	elseif empty(l:list)
		echo 'Nothing to remove from yanked'
		return
	else
		let l:oldlen = len(s:yanked)
		for l:path in l:list
			let l:i = index(s:yanked, l:path)
			if l:i == -1
				echo '"'.l:path.'" is not yanked'
			else
				call remove(s:yanked, l:i)
			endif
		endfor
		if len(s:yanked) != l:oldlen
			echo 'Yanked list shrunk by '.(l:oldlen - len(s:yanked)).' (from '.l:oldlen.' to '.len(s:yanked).')'
			let s:yankedtick += 1
			if type(a:list) != v:t_list
				call filter(b:fm_marked, 0)
				let b:fm_markedtick += 1
			endif
		elseif type(a:list) == v:t_list
			return
		endif
	endif
	let l:winview = winsaveview()
	call s:printtree()
	call winrestview(l:winview)
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
	let l:success = 0

	let l:existing = map(copy(l:list), 'fnamemodify(v:val, ":t")')
	call filter(l:existing, '!empty(glob(escape(fnameescape(l:destdir.v:val), "~"), 1, 1, 1))')
	if !empty(l:existing)
		echo 'Destinations already exist:'
		echo ' '.join(l:existing, "\n ")
		if confirm("Overwrite?", "&No\n&Yes") < 2
			echo 'Nothing pasted'
			return
		endif
	endif

	" Always faster than two filters
	let l:files = []
	let l:dirs = []
	for l:path in l:list
		call add(getftype(l:path) == 'dir' ? l:dirs : l:files, l:path)
	endfor

	if !empty(l:files)
		echo 'Files to paste:'
		echo ' '.join(l:files, "\n ")
		if confirm("Paste printed files?", "&No\n&Yes") < 2
			echo 'Files not pasted'
		else
			silent let l:output = system('cp '.join(map(add(l:files, l:destdir), 'shellescape(v:val, 0)'), ' '))
			if v:shell_error
				echohl ErrorMsg
				echomsg 'Failed to paste files: '.l:output
				echohl None
			endif
			let l:success = l:success || !v:shell_error
		endif
	endif

	if !empty(l:dirs)
		echo 'Directories to paste:'
		echo ' '.join(l:dirs, "\n ")
		if confirm("Paste printed directories?", "&No\n&Yes") < 2
			echo 'Directories not pasted'
		else
			silent let l:output = system('cp -r '.join(map(add(l:dirs, l:destdir), 'shellescape(v:val, 0)'), ' '))
			if v:shell_error
				echohl ErrorMsg
				echomsg 'Failed to paste directories: '.l:output
				echohl None
			endif
			let l:success = l:success || !v:shell_error
		endif
	endif

	if !a:leave && l:success
		call filter(l:list, 0)
		let s:yankedtick += a:doyanked
		let b:fm_markedtick += !a:doyanked
	endif
	call s:refreshtree(0)
endfun  " }}}


fun! s:deletemarked(doyanked, list=0)  " {{{
	if a:doyanked && empty(s:yanked)
		echo 'Nothing currently yanked'
		return
	endif
	let l:list = a:doyanked ? s:yanked : b:fm_marked
	let l:list = type(a:list) == v:t_list ? a:list : l:list
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
	let l:reset = 0

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
			for l:path in l:files
				if delete(l:path)
					echohl ErrorMsg
					echomsg 'Failed to delete "'.l:path.'"'
					echohl None
				elseif !l:reset
					let l:reset = 1
				endif
			endfor
		endif
	endif

	if !empty(l:dirs)
		echo 'Directories to delete:'
		echo ' '.join(l:dirs, "\n ")
		let l:choice = confirm("Delete printed directories?", "&No\n&Empty only\n&All")
		if l:choice < 2
			echo 'Directories not deleted'
		else
			let l:choice = l:choice == 2 ? 'd' : 'rf'
			" Sort without s:sortfunc here: child dirs first
			for l:path in reverse(sort(l:dirs))
				if delete(l:path, l:choice)
					echohl ErrorMsg
					echomsg 'Failed to delete "'.l:path.'"'
					echohl None
				elseif !l:reset
					let l:reset = 1
				endif
			endfor
		endif
	endif

	if l:reset
		call filter(l:list, 0)
		let s:yankedtick += a:doyanked && type(a:list) != v:t_list
		let b:fm_markedtick += !a:doyanked && type(a:list) != v:t_list
		" Don't notify if path is not found (deleted)
		silent call s:refreshtree(0)
	endif
endfun  " }}}


fun! s:renamemarked()  " {{{
	let l:cmp = b:fm_treeroot == '/' ? '/' : b:fm_treeroot.'/'
	if len(b:fm_marked) > 1
		let l:marked = []
		for l:path in sort(b:fm_marked)
			if l:path[:len(l:cmp)-1] ==# l:cmp
				call add(l:marked, l:path[len(b:fm_treeroot):])
			else
				echo 'Ignoring "'.l:path.'"'
			endif
		endfor
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
		if empty(l:markedtree)
			echo 'Nothing marked in current tree'
			return
		endif
		call s:renametree(l:markedtree)
		return
	endif

	let l:name = empty(b:fm_marked) ? s:undercursor(0) : b:fm_marked[0]
	if l:name[:len(l:cmp)-1] !=# l:cmp
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
	else
		let l:destination = s:simplify(substitute(fnamemodify(l:name, ':h'), '/$', '', '').'/'.l:destination)
		let l:err = s:renamebylist([l:name], [l:destination])
		" Probably renaming the file under the cursor
		silent call s:refreshtree(0)
		if !l:err && l:destination[:len(l:cmp)-1] ==# l:cmp
			silent call s:movecursorbypath(l:destination)
		endif
	endif
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

	delcommand Mark
	delcommand Filter
	delcommand Bookmark
	delcommand Delbookmark
	mapclear <buffer>
	nnoremap <buffer>  <cr>   <cmd>call <sid>renamefinish(1)<cr>
	inoremap <buffer>  <cr>   <esc><cmd>call <sid>renamefinish(1)<cr>
	nnoremap <buffer>  <esc>  <cmd>call <sid>renamefinish(0)<cr>
	au filemanager BufLeave <buffer> ++once call s:renamefinish(-1)
	setl undolevels=-123456  " based on :help 'undolevels'
endfun  " }}}


fun! s:renamefinish(do)  " {{{
	if a:do > 0
		if line('$') - 2 != len(b:fm_renamefrom)
			echo 'Number of lines changed. Aborted'
			call s:renamefinish(0)
			return
		endif
		let l:changed = filter(range(3, line('$')), 'b:fm_renamefrom[v:val-3] !=# getline(v:val)')
		if empty(l:changed)
			echo 'Nothing to rename'
			call s:renamefinish(0)
			return
		endif
		let l:renameto = map(copy(l:changed), 's:undercursor(1, v:val)')
		let l:renamefrom = map(copy(l:changed), 's:undercursor(1, v:val - 3, b:fm_renamefrom)')
		call s:renamebylist(l:renamefrom, l:renameto)
	endif

	au! filemanager BufLeave <buffer>
	unlet b:fm_renamefrom
	mapclear <buffer>
	setl nomodifiable readonly undolevels=-1
	call s:definemapcmd()
	call s:refreshtree(-1)
endfun  " }}}


fun! s:renamebylist(listfrom, listto)  " {{{
	let l:existing = filter(copy(a:listto), '!empty(glob(escape(fnameescape(v:val), "~"), 1, 1, 1))')
	if !empty(l:existing)
		echo 'Destinations already exist:'
		echo ' '.join(l:existing, "\n ")
		if confirm("Overwrite?", "&No\n&Yes") < 2
			echo 'Nothing moved'
			return 1
		endif
	endif

	let l:success = 0
	let l:unmark = 0
	let l:unyank = 0
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
		if !l:unmark
			let l:unmark += index(b:fm_marked, a:listfrom[l:i]) != -1
			let l:unmark += index(b:fm_marked, a:listto[l:i]) != -1
		endif
		if !l:unyank
			let l:unyank += index(s:yanked, a:listfrom[l:i]) != -1
			let l:unyank += index(s:yanked, a:listto[l:i]) != -1
		endif
		if isdirectory(a:listto[l:i])
			" \= is simpler than doing all the escape() and hope
			let l:subwith = a:listto[l:i].'/'
			for l:j in range(l:i+1, len(a:listfrom)-1)
				let a:listfrom[l:j] = substitute(a:listfrom[l:j], '^\V'.escape(a:listfrom[l:i], '\').'/', '\=l:subwith', '')
			endfor
			call s:movetreecontents(a:listfrom[l:i], a:listto[l:i])
		endif
	endfor

	if l:unmark
		let b:fm_markedtick += 1
		call filter(b:fm_marked, 0)
	endif
	if l:unyank
		let s:yankedtick += 1
		call filter(s:yanked, 0)
	endif
	return !l:success
endfun  " }}}


fun! s:visualcmd(cmd, ends)  " {{{
	let l:list = []
	for l:linenr in range(min(a:ends), max(a:ends))
		let l:path = s:undercursor(0, l:linenr)
		if l:linenr < 3
			echo 'Skipping "'.l:path.'"'
		else
			call add(l:list, l:path)
		endif
	endfor
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
	endif
endfun  " }}}


fun! s:processcmdline()  " {{{
	if getcmdtype() != ':' || getcmdline() !~# '\$\(yan\|mar\)ked'
		return getcmdline()
	endif

	if s:resetmarkedonsuccess
		" Should refresh tree only after resetting everything
		au! filemanager ShellCmdPost <buffer>
	endif
	" Attempt to not clutter memory with copy()
	if getcmdline() =~# '[^\\]\$yanked'
		if s:resetmarkedonsuccess
			au filemanager ShellCmdPost <buffer> ++once
			\ if !v:shell_error | call filter(s:yanked, 0) | let s:yankedtick += 1 | endif
		endif
		if s:yankedshtick < s:yankedtick
			let s:yankedsh = empty(s:yanked) ? ' ' :
			    \ ' '.join(map(copy(s:yanked), 'shellescape(v:val, 1)'), ' ').' '
			let s:yankedshtick = s:yankedtick
		endif
	endif

	if getcmdline() =~# '[^\\]\$marked'
		if s:resetmarkedonsuccess
			au filemanager ShellCmdPost <buffer> ++once
			\ if !v:shell_error | call filter(b:fm_marked, 0) | let b:fm_markedtick += 1 | endif
		endif
		if b:fm_markedshtick < b:fm_markedtick
			let b:fm_markedsh = empty(b:fm_marked) ? ' ' :
			    \ ' '.join(map(copy(b:fm_marked), 'shellescape(v:val, 1)'), ' ').' '
			let b:fm_markedshtick = b:fm_markedtick
		endif
	endif
	if s:resetmarkedonsuccess
		" Also restores this autocmd from s:initialize()
		au filemanager ShellCmdPost  <buffer>  call s:refreshtree(-1)
	endif

	let l:split = split(getcmdline(), '[^\\]\zs\$yanked', 1)
	call map(l:split, 'substitute(v:val, ''\\\$yanked'', "$yanked", "g")')
	" Cannot join here since yanked filenames may include '$marked'
	call map(l:split, 'split(v:val, ''[^\\]\zs\$marked'', 1)')
	" Avoid potential problems of nested v:val usage in map(map())
	for l:list in l:split
		call map(l:list, 'substitute(v:val, ''\\\$marked'', "$marked", "g")')
	endfor
	call map(l:split, 'join(v:val, b:fm_markedsh)')
	return join(l:split, s:yankedsh)
endfun  " }}}


fun! s:checkconfig()  " {{{
	if exists('s:checkconfigdone')
		return
	endif
	let s:checkconfigdone = 1
	let s:sortorder = s:checksortorder(s:sortorder)
	echohl ErrorMsg
	if s:winsize < 1 || s:winsize > 99
		echomsg 'Invalid window size "'.s:winsize.'". Variable set to 20'
		let s:winsize = 20
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


fun! s:definemapcmd()  " {{{
	" Separete function because of s:renamemarked()
	command! -buffer -bang -nargs=1  Mark         call s:markbypat(<q-args>, <bang>0)
	command! -buffer -bang -nargs=?  Filter       call s:filtercmd(<q-args>, <bang>0)
	command! -buffer -bang -nargs=? -complete=customlist,s:bookmarksuggest
	                               \ Bookmark     call s:bookmarkcmd(<bang>0, <q-args>)
	command! -buffer -bang -nargs=? -complete=customlist,s:bookmarksuggest
	                               \ Delbookmark  call s:bookmarkdel(<bang>0, <q-args>)

	" No need for <silent> with <cmd>
	nnoremap <nowait> <buffer>  ,        zh
	nnoremap <nowait> <buffer>  .        zl
	nnoremap <nowait> <buffer>  <        zH
	nnoremap <nowait> <buffer>  >        zL
	nnoremap <nowait> <buffer>  f        <cmd>call <sid>openbyname()<cr>
	nnoremap <nowait> <buffer>  F        <cmd>call <sid>openbyfind()<cr>
	nnoremap <nowait> <buffer>  d        <cmd>call <sid>newdir()<cr>
	nnoremap <nowait> <buffer>  <cr>     <cmd>call <sid>open(<sid>undercursor(1), 0)<cr>
	nnoremap <nowait> <buffer>  v        <cmd>call <sid>open(<sid>undercursor(1), 1)<cr>
	nnoremap <nowait> <buffer>  o        <cmd>call <sid>open(<sid>undercursor(1), 2)<cr>
	nnoremap <nowait> <buffer>  O        <cmd>call <sid>open(<sid>undercursor(1), 3)<cr>
	nnoremap <nowait> <buffer>  t        <cmd>call <sid>open(<sid>undercursor(1), 4)<cr>
	nnoremap <nowait> <buffer>  s        <cmd>call <sid>open(<sid>undercursor(1), 5)<cr>
	nnoremap <nowait> <buffer>  E        <cmd>call <sid>open(<sid>undercursor(1), 6)<cr>
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
	nnoremap <nowait> <buffer>  zo       <cmd>call <sid>toggledir(<sid>undercursor(1), 2)<cr>
	nnoremap <nowait> <buffer>  c        <cmd>call <sid>cmdundercursor()<cr>
	nnoremap <nowait> <buffer>  x        <cmd>call <sid>openexternal(<sid>undercursor(1))<cr>
	nnoremap <nowait> <buffer>  gs       <cmd>call <sid>statcmd(<sid>undercursor(1))<cr>
	nnoremap <nowait> <buffer>  gf       <cmd>call <sid>filecmd(<sid>undercursor(1))<cr>
	nnoremap <nowait> <buffer>  gr       <cmd>call <sid>togglesortreverse()<cr>
	nnoremap <nowait> <buffer>  S        <cmd>call <sid>setsortmethod()<cr>
	nnoremap <nowait> <buffer>  gS       <cmd>call <sid>setsortorder()<cr>
	nnoremap <nowait> <buffer>  gi       <cmd>call <sid>setignorecase()<cr>
	nnoremap <nowait> <buffer>  gh       <cmd>call <sid>toggleshowhidden()<cr>
	nnoremap <nowait> <buffer>  gG       <cmd>call <sid>togglerespectgitignore()<cr>
	nnoremap <nowait> <buffer>  gd       <cmd>call <sid>togglefilterdirs()<cr>
	nnoremap <nowait> <buffer>  gF       <cmd>call <sid>printfilters()<cr>
	nnoremap <nowait> <buffer>  <c-l>    <cmd>call <sid>refreshtree(0)<cr><c-l>
	nnoremap <nowait> <buffer>  <c-r>    <cmd>call <sid>refreshtree(1)<cr>
	nnoremap <nowait> <buffer>  i        <cmd>call <sid>mark([line('.')])<cr>
	nnoremap <nowait> <buffer>  I        <cmd>call <sid>resetmarked()<cr>
	nnoremap <nowait> <buffer>  r        <cmd>call <sid>renamemarked()<cr>
	nnoremap <nowait> <buffer>  R        <cmd>call <sid>renametree()<cr>
	nnoremap <nowait> <buffer>  D        <cmd>call <sid>deletemarked(0)<cr>
	nnoremap <nowait> <buffer>  y        <cmd>call <sid>yankmarked()<cr>
	nnoremap <nowait> <buffer>  Y        <cmd>call <sid>resetyanked()<cr>
	nnoremap <nowait> <buffer>  p        <cmd>call <sid>pastemarked(0, 0)<cr>
	nnoremap <nowait> <buffer>  P        <cmd>call <sid>pastemarked(0, 1)<cr>
	nnoremap <nowait> <buffer>  zp       <cmd>call <sid>pastemarked(1, 0)<cr>
	nnoremap <nowait> <buffer>  zP       <cmd>call <sid>pastemarked(1, 1)<cr>
	nnoremap <nowait> <buffer>  X        <cmd>call <sid>deletemarked(1)<cr>
	nnoremap <nowait> <buffer>  b        <nop>
	nnoremap <nowait> <buffer>  B        <nop>
	nnoremap <nowait> <buffer>  b<cr>    <cmd>call <sid>printbookmarks()<cr>
	cnoremap <nowait> <buffer>  <cr>     <c-\>e<sid>processcmdline()<cr><cr>
	xnoremap <nowait> <buffer> <expr>  i  '<esc><cmd>call <sid>mark(['.line('.').', '.line('v').'])<cr>'
	xnoremap <nowait> <buffer> <expr>  y  '<esc><cmd>call <sid>visualcmd("y", ['.line('.').', '.line('v').'])<cr>'
	xnoremap <nowait> <buffer> <expr>  Y  '<esc><cmd>call <sid>visualcmd("Y", ['.line('.').', '.line('v').'])<cr>'
	xnoremap <nowait> <buffer> <expr>  D  '<esc><cmd>call <sid>visualcmd("D", ['.line('.').', '.line('v').'])<cr>'
	for l:name in s:bookmarknames
		exe 'nnoremap <nowait> <buffer>  B'.l:name.'  <cmd>call <sid>bookmarksave('.string(l:name).', 0)<cr>'
		exe 'nnoremap <nowait> <buffer>  b'.l:name.'  <cmd>call <sid>bookmarkrestore('.string(l:name).')<cr>'
	endfor

	if s:enablemouse
		nmap <nowait> <buffer>  <2-LeftMouse>   <cr>
	endif
endfun  " }}}


fun! s:initialize(path, aux)  " {{{
	" nofile is necessary for independent views of the same directory
	setl bufhidden=wipe buftype=nofile noswapfile
	setl nomodifiable readonly undolevels=-1
	setl nonumber nowrap nofoldenable
	setl conceallevel=3 concealcursor=nc

	" Mappings, commands, syntax, autocmds {{{
	call s:definemapcmd()

	syntax clear
	syntax spell notoplevel
	exe 'syntax match fm_regularfile  ".*'.s:seppat.'$"        contains=fm_depth,fm_marked,fm_yanked,fm_sepregfile'
	exe 'syntax match fm_directory    ".*'.s:seppat.'/$"       contains=fm_depth,fm_marked,fm_yanked,fm_ftypeind'
	exe 'syntax match fm_executable   ".*'.s:seppat.'\*$"      contains=fm_depth,fm_marked,fm_yanked,fm_ftypeind'
	exe 'syntax match fm_symlink      ".*'.s:seppat.'@$"       contains=fm_depth,fm_marked,fm_yanked,fm_ftypeind'
	exe 'syntax match fm_symlinkmis   ".*'.s:seppat.'!@$"      contains=fm_depth,fm_marked,fm_yanked,fm_ftypeind'
	exe 'syntax match fm_socket       ".*'.s:seppat.'=$"       contains=fm_depth,fm_marked,fm_yanked,fm_ftypeind'
	exe 'syntax match fm_fifo         ".*'.s:seppat.'|$"       contains=fm_depth,fm_marked,fm_yanked,fm_ftypeind'
	exe 'syntax match fm_ftypeind     "'.s:seppat.s:filetypepat.'$"  contains=fm_sepftype contained'
	exe 'syntax match fm_sepftype     "'.s:seppat.'\ze[\*@=|/]$"     conceal contained'
	exe 'syntax match fm_sepftype     "'.s:seppat.'!\ze@$"           conceal contained'
	exe 'syntax match fm_sepregfile   "'.s:seppat.'$"                conceal contained'
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

	" BufReadCmd needed for when the user runs :edit to reload the buffer
	au! filemanager * <buffer>
	au filemanager BufReadCmd    <buffer>  call s:initialize(b:fm_treeroot, b:fm_auxiliary)
	au filemanager BufEnter      <buffer>  call s:refreshtree(0)
	au filemanager BufUnload     <buffer>  call s:exit(str2nr(expand('<abuf>')))
	au filemanager CmdlineEnter  <buffer>  call s:cmdlineenter(expand('<afile>'))
	au filemanager ShellCmdPost  <buffer>  call s:refreshtree(-1)
	" }}}

	for l:var in s:tabvars
		exe 'let b:fm_'.l:var.' = get(t:, "filemanager_".l:var, s:'.l:var.')'
	endfor
	let b:fm_filters = []
	let b:fm_marked = []
	let b:fm_markedtick = 0
	let b:fm_markedsh = ''
	let b:fm_markedshtick = 0

	let b:fm_treeroot = substitute(a:path, '[^/]\zs/$', '', '')
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

	call s:printtree()
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
		if s:dirreadable(b:fm_treeroot)
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
		if s:bookmarkonbufexit
			call s:bookmarkbackup(a:bufnr)
		endif
	endfor
	" The autocmds and variables are unset by vim (bufhidden=wipe)
endfun  " }}}
" }}}
