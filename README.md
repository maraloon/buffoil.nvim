# buffoil.nvim

[oil.nvim](https://github.com/stevearc/oil.nvim/) but for buffers

it's alpha release, so feel free to install and report bugs 😎🤙

![showcase](readme/preview.png) 


## Features
- Has separate filenames buffer and paths buffer, cause 90% time we understand what the file is only by it's name and other part of path is only visual noise
- File preview
- MRU sort. Current buffer always on top, alter buffer always second and selected by default
- select on `<cr>`
- exit on `<esc>` or `<C-c>`
- delete line or lines will delete buffer(s) from buffers list
- filter by `/`, not matching files will be deleted from view (temporary). You can do it several times to filter on filtered

## Install

### Lazy:

```
{
    'maraloon/buffoil.nvim',
    keys = {
        { '#', function() require("buffoil").show() end, desc = 'Oil buffer' }
    }
}
```
