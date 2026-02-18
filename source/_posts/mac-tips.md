---
title: "自用的Mac小技巧"
date: 2019-11-16 23:42:05
permalink: 2019/11/16/%E8%87%AA%E7%94%A8%E7%9A%84Mac%E5%B0%8F%E6%8A%80%E5%B7%A7/
tags:
  - "工具技巧"
---

<h3 id=""><a href="#" class="headerlink" title=""></a></h3><h4 id="使用键盘快捷键来快速给文件添加-删除-标签："><a href="#使用键盘快捷键来快速给文件添加-删除-标签：" class="headerlink" title="使用键盘快捷键来快速给文件添加 /删除 标签："></a>使用键盘快捷键来快速给文件添加 /删除 标签：</h4><ul><li>添加标签: 选择文件，然后使用 Control-1 到 Control-7 来添加（或移除）个人收藏标签。</li><li>移除标签: 选择文件，使用 Control-0（零）会移除文件的所有标签。</li></ul><h4 id="设置在终端中启动各种-app-的命令"><a href="#设置在终端中启动各种-app-的命令" class="headerlink" title="设置在终端中启动各种 app 的命令"></a>设置在终端中启动各种 app 的命令</h4><p>以 Typora 为例：</p><ol><li><p>通过添加别名<code>ty</code>来快速启动 Typora。在 <code>~/.bash_profile</code> (这个文件好像要自己建) 中添加 <code>alias ty=&quot;open -a typora&quot;</code></p></li><li><p>添加完成后，执行<code>source ~/.bash_profile</code>(source [executable_file] = ./executable_file ), 就可以在命令行中用 <code>ty [filepath/filename]</code> 以快速用 Typora 打开并编辑文件</p></li></ol><h4 id="文本编辑类"><a href="#文本编辑类" class="headerlink" title="文本编辑类"></a>文本编辑类</h4><ol><li><p><strong>文字退格</strong>： TAB 右移，按 SHIFT+TAB 左移</p></li><li><p><strong>输入 ⍺，β，𝞬 等特殊字符</strong>：用（⌘⌃-Space）呼出 Mac emoji 输入框，搜索 alpha, beta 等想要的字符即可</p></li><li><p><strong>在 word 中输入数学公式</strong>：(‘’⌃’’ + ‘’=’’) 即可呼出word 公式编辑框，输入 LaTeX 公式即可</p></li></ol><h4 id="解决网络端口占用"><a href="#解决网络端口占用" class="headerlink" title="解决网络端口占用"></a>解决网络端口占用</h4><ol><li>查看是占用所需端口的进程：终端输入<code>lsof -i tcp:[port]</code> 将port换成被占用的端口(如：4000)，将会出现占用端口的进程信息。</li></ol><img src="https://tva1.sinaimg.cn/large/006y8mN6gy1g917abws8fj30zk02h762.jpg" srcset="/img/loading.gif" alt="查看占用端口的进程"  /><ol start="2"><li>Kill 进程：找到进程的PID,使用kill命令：<code>kill [PID]</code>（进程的PID，如71881），杀死对应的进程，这样所占端口就被释放啦</li></ol>
