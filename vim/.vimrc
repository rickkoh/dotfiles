" theme
:color ego

" tab = 2 spaces
set expandtab
set tabstop=2
set softtabstop=2
set shiftwidth=2

" plugins
:let g:rainbow_active=1
:set laststatus=2

" blinking cursor
:let &t_SI = "\e[6 q"
:let &t_EI = "\e[2 q"
:augroup myCmds
:au!
:autocmd VimEnter * silent !echo -ne "\e[2 q"
:augroup END

" autoindent
:set cindent

" highlight search
:set hlsearch

" others
:set number
:set showcmd
:set backspace=indent,eol,start
:syntax enable
:highlight Normal ctermbg=0
:highlight LineNr ctermbg=0

" custom mapsping
:map <space> /\c
:map ~ :NERDTree<Return>
:nnoremap + :res +5<CR>
:nnoremap _ :res -5<CR>
:nnoremap ) :vertical res +5<CR>
:nnoremap ( :vertical res -5<CR>

" fold
" :setlocal foldmethod=syntax

" relative number
" :set relativenumber

