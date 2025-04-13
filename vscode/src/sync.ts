import * as vscode from 'vscode';
import * as net from 'net';
import * as os from 'os';
import * as path from 'path';

interface Config {
    autoReload: boolean;
    syncInterval: number;
    socketPath: string;
}

interface Position {
    line: number;
    character: number;
}

interface ViewState {
    cursor: Position;
    scroll: {
        topLine: number;
        bottomLine: number;
    };
}

interface TabInfo {
    path: string;
    active: boolean;
    viewState?: ViewState;
}

interface WindowLayout {
    type: 'leaf' | 'vsplit' | 'hsplit';
    buffers?: TabInfo[];
    children?: WindowLayout[];
    size?: number;
}

interface Message {
    type: 'editor_group' | 'buffer_change';
    data: WindowLayout | { 
        path: string;
        viewState?: ViewState;
    };
    from_nvim?: boolean;
}

export class SyncManager {
    private config: Config;
    private client: net.Socket | null = null;
    private disposables: vscode.Disposable[] = [];
    private outputChannel: vscode.OutputChannel;
    private isHandlingNeovimMessage: boolean = false;
    private messageBuffer: string = '';  // Add message buffer
    private lastWindowLayout: WindowLayout | null = null; // 存储上一次窗口布局
    private lastSyncedFiles: Map<string, number> = new Map(); // 存储最近同步的文件及其时间戳

    constructor(config: Config) {
        this.config = this.normalizeConfig(config);
        this.outputChannel = vscode.window.createOutputChannel('Shadow Play');
        this.outputChannel.show();
        this.log('Shadow Play initialized');
    }

    private normalizeConfig(config: Config): Config {
        // Use workspace root directory if socketPath is not specified
        let socketPath = config.socketPath;
        if (!socketPath && vscode.workspace.workspaceFolders && vscode.workspace.workspaceFolders.length > 0) {
            socketPath = path.join(vscode.workspace.workspaceFolders[0].uri.fsPath, 'shadow-play.sock');
        }
        
        return {
            ...config,
            socketPath: socketPath ? socketPath.replace('~', os.homedir()) : ''
        };
    }

    public updateConfig(newConfig: Config): void {
        this.config = this.normalizeConfig(newConfig);
        this.restart();
    }

    public start(): void {
        this.connect();
    }

    private connect(): void {
        if (this.client) {
            return;
        }

        this.log('Connecting to Neovim...');
        this.client = net.createConnection(this.config.socketPath)
            .on('connect', () => {
                this.log('Connected to Neovim');
                this.syncEditorGroups();
            })
            .on('error', (err) => {
                this.log(`Connection error: ${err}`);
                this.client = null;
                // Try to reconnect after interval
                setTimeout(() => this.connect(), this.config.syncInterval);
            })
            .on('data', (data) => {
                // Add new data to buffer
                this.messageBuffer += data.toString();
                
                // Process all complete messages
                while (true) {
                    const nullIndex = this.messageBuffer.indexOf('\0');
                    if (nullIndex === -1) {
                        // No end character found, wait for more data
                        break;
                    }
                    
                    // Extract a complete message
                    const messageStr = this.messageBuffer.substring(0, nullIndex);
                    // Update buffer, remove processed message
                    this.messageBuffer = this.messageBuffer.substring(nullIndex + 1);
                    
                    if (!messageStr) continue;
                    
                    try {
                        this.log(`Received data: ${messageStr}`);
                        const message: Message = JSON.parse(messageStr);
                        this.handleMessage(message);
                    } catch (err) {
                        this.log(`Failed to parse message: ${err}`);
                    }
                }
            })
            .on('close', () => {
                this.log('Connection closed');
                this.client = null;
                this.messageBuffer = '';  // Clear buffer
                // Try to reconnect after interval
                setTimeout(() => this.connect(), this.config.syncInterval);
            });
    }

    private async handleMessage(message: Message): Promise<void> {
        this.log(`Handling message: ${message.type}`);
        this.isHandlingNeovimMessage = true;
        try {
            switch (message.type) {
                case 'editor_group':
                    await this.handleEditorGroupSync(message.data as WindowLayout);
                    break;
                case 'buffer_change':
                    await this.handleBufferChange(message.data as { path: string });
                    break;
            }
        } finally {
            setTimeout(() => {
                this.isHandlingNeovimMessage = false;
            }, 100);
        }
    }

    private shouldIgnoreFile(filePath: string): boolean {
        // Ignore special files
        const ignoredPatterns = [
            /^git:\/\/.*/,           // Git protocol files
            /^untitled:.*/,          // Untitled files
            /^output:.*/,            // Output windows
            /^extension-output-.*/,  // Extension outputs
            /^markdown-preview-.*/,  // Markdown previews
            /^vscode-remote:.*/,     // VSCode remote files
            /^vscode-settings:.*/,   // VSCode settings
            /^vscode-workspace:.*/,  // VSCode workspace
            /^vscode-extension:.*/,  // VSCode extension
            /^vscode-.*/,            // Other VSCode special files
        ];

        return ignoredPatterns.some(pattern => pattern.test(filePath));
    }

    private async handleEditorGroupSync(layout: WindowLayout): Promise<void> {
        this.log(`Handling window layout sync`);
        await this.applyWindowLayout(layout);
    }

    private async applyWindowLayout(layout: WindowLayout, viewColumn: vscode.ViewColumn = vscode.ViewColumn.One): Promise<void> {
        // 计算传入布局中的 editor group 总数
        const countEditorGroups = (layout: WindowLayout): number => {
            if (layout.type === 'leaf') {
                return 1;
            }
            return (layout.children || []).reduce((sum, child) => sum + countEditorGroups(child), 0);
        };

        const vimGroupCount = countEditorGroups(layout);
        const vscodeGroups = vscode.window.tabGroups.all;

        // 如果 editor group 数量一致，使用现有的 VSCode editor groups
        if (vimGroupCount === vscodeGroups.length) {
            // 收集所有叶子节点的 buffers
            const collectBuffers = (layout: WindowLayout): TabInfo[][] => {
                if (layout.type === 'leaf') {
                    return [layout.buffers || []];
                }
                return (layout.children || []).flatMap(child => collectBuffers(child));
            };

            const allBuffers = collectBuffers(layout);
            
            // 为每个 VSCode editor group 应用对应的 buffers
            for (let i = 0; i < vscodeGroups.length; i++) {
                const buffers = allBuffers[i];
                if (!buffers) continue;

                for (const buffer of buffers) {
                    try {
                        if (this.shouldIgnoreFile(buffer.path)) {
                            continue;
                        }

                        const uri = vscode.Uri.file(buffer.path);
                        
                        // 检查当前 editor group 中是否已经打开了这个文件
                        const editor = vscode.window.visibleTextEditors.find(
                            e => e.document.uri.fsPath === uri.fsPath && 
                                 e.viewColumn === vscodeGroups[i].viewColumn
                        );

                        if (editor) {
                            // 如果文件已经打开且是激活状态或有视图状态，需要处理
                            if (buffer.active || buffer.viewState) {
                                // 如果有视图状态，同步它
                                if (buffer.viewState) {
                                    const position = new vscode.Position(
                                        buffer.viewState.cursor.line,
                                        buffer.viewState.cursor.character
                                    );
                                    editor.selection = new vscode.Selection(position, position);
                                    editor.revealRange(
                                        new vscode.Range(
                                            buffer.viewState.scroll.topLine, 0,
                                            buffer.viewState.scroll.bottomLine, 0
                                        ),
                                        vscode.TextEditorRevealType.InCenter
                                    );
                                }
                                // 如果需要激活，激活它
                                if (buffer.active) {
                                    await vscode.window.showTextDocument(editor.document, {
                                        viewColumn: vscodeGroups[i].viewColumn,
                                        preserveFocus: false,
                                        preview: false
                                    });
                                }
                            }
                            continue;  // 文件已经打开，跳过后续处理
                        }

                        // 文件未打开，需要打开它
                        const doc = await vscode.workspace.openTextDocument(uri);
                        
                        // 如果是激活的 buffer 或有视图状态，需要显示它
                        if (buffer.active) {
                            const newEditor = await vscode.window.showTextDocument(doc, {
                                viewColumn: vscodeGroups[i].viewColumn,
                                preview: false,
                                preserveFocus: true  // 只有激活的 buffer 才获取焦点
                            });

                            // 如果有视图状态，同步它
                            if (buffer.viewState) {
                                const position = new vscode.Position(
                                    buffer.viewState.cursor.line,
                                    buffer.viewState.cursor.character
                                );
                                newEditor.selection = new vscode.Selection(position, position);
                                newEditor.revealRange(
                                    new vscode.Range(
                                        buffer.viewState.scroll.topLine, 0,
                                        buffer.viewState.scroll.bottomLine, 0
                                    ),
                                    vscode.TextEditorRevealType.InCenter
                                );
                            }
                        } else {
                            // 只需要打开文件，不需要显示或激活
                            await vscode.workspace.openTextDocument(uri);
                        }
                    } catch (error) {
                        this.log(`Failed to handle buffer ${buffer.path}: ${error}`);
                    }
                }
            }
        } else {
            this.log(`Editor group count mismatch: ${vimGroupCount} !== ${vscodeGroups.length}`);
            
            try {
                // 获取当前编辑器布局
                const editorLayout = await vscode.commands.executeCommand('vscode.getEditorLayout');
                this.log(`Current editor layout: ${JSON.stringify(editorLayout)}`);
                
                // 关闭所有编辑器和编辑器组
                await vscode.commands.executeCommand('workbench.action.closeAllEditors');
                
                // 使用 vscode.setEditorLayout 设置编辑器布局
                // 根据传入的 layout 构建 VSCode 的编辑器布局
                const vsCodeLayout = this.convertToVSCodeLayout(layout);
                await vscode.commands.executeCommand('vscode.setEditorLayout', vsCodeLayout);
                
                // 重建布局中的文件
                await this.restoreBuffersInLayout(layout);
            } catch (error) {
                this.log(`Failed to restore layout with setEditorLayout: ${error}`);
                // 如果使用新API失败，退回到原来的布局恢复方式
                await this.createNewLayout(layout);
            }
        }
    }

    /**
     * 将我们的布局结构转换为VSCode的编辑器布局格式
     */
    private convertToVSCodeLayout(layout: WindowLayout): any {
        const convertLayout = (node: WindowLayout): any => {
            if (node.type === 'leaf') {
                return {
                    groups: [{}]  // 空对象表示一个编辑器组
                };
            } else if (node.type === 'vsplit' || node.type === 'hsplit') {
                const orientation = node.type === 'vsplit' ? 0 : 1;  // 0表示水平排列（垂直分割），1表示垂直排列（水平分割）
                const groups = (node.children || []).map(child => {
                    const result = convertLayout(child);
                    return result.groups ? result.groups[0] : {};
                });
                
                // 设置每个子组的尺寸
                for (let i = 0; i < groups.length; i++) {
                    if (node.children?.[i].size) {
                        groups[i].size = node.children[i].size;
                    }
                }
                
                return {
                    orientation,
                    groups
                };
            } else {
                // 默认返回简单布局
                return {
                    groups: [{}]
                };
            }
        };
        
        const result = convertLayout(layout);
        this.log(`Converted layout: ${JSON.stringify(result)}`);
        return result;
    }
    
    /**
     * 恢复布局中所有缓冲区
     */
    private async restoreBuffersInLayout(layout: WindowLayout): Promise<void> {
        const collectBufferInfos = (layout: WindowLayout): {buffers: TabInfo[], viewColumn: number}[] => {
            if (layout.type === 'leaf') {
                return [{
                    buffers: layout.buffers || [],
                    viewColumn: vscode.ViewColumn.One  // 默认值，后面会更新
                }];
            }
            
            const result: {buffers: TabInfo[], viewColumn: number}[] = [];
            let viewColumn = vscode.ViewColumn.One;
            
            for (const child of (layout.children || [])) {
                const childBuffers = collectBufferInfos(child);
                
                // 更新视图列
                for (let i = 0; i < childBuffers.length; i++) {
                    childBuffers[i].viewColumn = viewColumn + i;
                }
                
                result.push(...childBuffers);
                viewColumn += childBuffers.length;
            }
            
            return result;
        };
        
        const bufferGroups = collectBufferInfos(layout);
        this.log(`Collecting buffer groups: ${JSON.stringify(bufferGroups)}`);
        
        // 打开每个缓冲区组中的文件
        for (const group of bufferGroups) {
            for (const buffer of group.buffers) {
                try {
                    if (this.shouldIgnoreFile(buffer.path)) {
                        continue;
                    }
                    
                    const uri = vscode.Uri.file(buffer.path);
                    const doc = await vscode.workspace.openTextDocument(uri);
                    
                    if (buffer.active) {
                        const editor = await vscode.window.showTextDocument(doc, {
                            viewColumn: group.viewColumn,
                            preserveFocus: !buffer.active,
                            preview: false
                        });
                        
                        if (buffer.viewState) {
                            const position = new vscode.Position(
                                buffer.viewState.cursor.line,
                                buffer.viewState.cursor.character
                            );
                            editor.selection = new vscode.Selection(position, position);
                            editor.revealRange(
                                new vscode.Range(
                                    buffer.viewState.scroll.topLine, 0,
                                    buffer.viewState.scroll.bottomLine, 0
                                ),
                                vscode.TextEditorRevealType.InCenter
                            );
                        }
                    }
                } catch (error) {
                    this.log(`Failed to restore buffer ${buffer.path}: ${error}`);
                }
            }
        }
    }

    /**
     * 创建新的窗口布局
     * @param layout 目标布局配置
     * @param viewColumn 当前视图列
     */
    private async createNewLayout(layout: WindowLayout, viewColumn: vscode.ViewColumn = vscode.ViewColumn.One): Promise<void> {
        if (layout.type === 'leaf') {
            // Handle leaf node
            for (const buffer of layout.buffers || []) {
                try {
                    if (this.shouldIgnoreFile(buffer.path)) {
                        continue;
                    }

                    const uri = vscode.Uri.file(buffer.path);
                    await vscode.workspace.openTextDocument(uri);

                    if (buffer.active) {
                        const doc = await vscode.window.showTextDocument(uri, {
                            viewColumn,
                            preserveFocus: !buffer.active
                        });

                        if (buffer.viewState) {
                            const position = new vscode.Position(
                                buffer.viewState.cursor.line,
                                buffer.viewState.cursor.character
                            );
                            doc.selection = new vscode.Selection(position, position);
                            doc.revealRange(
                                new vscode.Range(
                                    buffer.viewState.scroll.topLine, 0,
                                    buffer.viewState.scroll.bottomLine, 0
                                ),
                                vscode.TextEditorRevealType.InCenter
                            );
                        }
                    }
                } catch (error) {
                    this.log(`Failed to handle buffer ${buffer.path}: ${error}`);
                }
            }
        } else {
            // Handle split node
            for (let i = 0; i < (layout.children || []).length; i++) {
                const child = layout.children![i];
                
                // 如果不是第一个子节点，需要先创建新的 editor group
                if (i > 0) {
                    const splitCommand = layout.type === 'vsplit' 
                        ? 'workbench.action.splitEditorRight'
                        : 'workbench.action.splitEditorDown';
                    await vscode.commands.executeCommand(splitCommand);
                }
                
                const nextColumn = layout.type === 'vsplit' 
                    ? viewColumn + i 
                    : viewColumn;
                await this.createNewLayout(child, nextColumn);
            }
        }
    }

    private async getEditorGroupsInfo(): Promise<WindowLayout> {
        const groups = vscode.window.tabGroups.all;
        if (groups.length === 0) {
            return {
                type: 'leaf',
                children: []
            };
        }

        // 获取每个group的buffer信息
        const groupBuffers: Map<number, TabInfo[]> = new Map();
        for (const group of groups) {
            const buffers: TabInfo[] = [];
            for (const tab of group.tabs) {
                if (!(tab.input instanceof vscode.TabInputText)) {
                    continue;
                }

                const uri = (tab.input as vscode.TabInputText).uri;
                if (this.shouldIgnoreFile(uri.toString())) {
                    continue;
                }

                // 尝试从visibleTextEditors获取编辑器
                let editor = vscode.window.visibleTextEditors.find(
                    e => e.document.uri.fsPath === uri.fsPath
                    && e.viewColumn === group.viewColumn
                );

                let viewState: ViewState | undefined;

                if (editor && tab.isActive) {  // 只有当编辑器可见且是激活状态时才获取视图状态
                    // 确保编辑器已经完全初始化
                    if (editor.visibleRanges && editor.visibleRanges.length > 0) {
                        const firstVisibleRange = editor.visibleRanges[0];
                        const lastVisibleRange = editor.visibleRanges[editor.visibleRanges.length - 1];
                        
                        viewState = {
                            cursor: {
                                line: editor.selection.active.line,
                                character: editor.selection.active.character
                            },
                            scroll: {
                                topLine: firstVisibleRange.start.line,
                                bottomLine: lastVisibleRange.end.line
                            }
                        };
                    }
                }

                buffers.push({
                    path: uri.fsPath,
                    active: tab.isActive,
                    viewState
                });
            }

            if (buffers.length > 0) {
                // 使用group.viewColumn作为索引
                groupBuffers.set(group.viewColumn, buffers);
            }
        }

        if (groupBuffers.size === 0) {
            return {
                type: 'leaf',
                buffers: []
            };
        }

        if (groupBuffers.size === 1) {
            // 只有一个编辑器组，直接返回
            return {
                type: 'leaf',
                buffers: groupBuffers.values().next().value
            };
        }

        try {
            // 获取VSCode的编辑器布局
            const editorLayout = await vscode.commands.executeCommand('vscode.getEditorLayout') as any;
            
            if (!editorLayout) {
                throw new Error("Failed to get editor layout");
            }

            // 创建一个跟踪索引的辅助变量
            let groupIndex = 0;
            
            // 根据editorLayout递归构建WindowLayout
            const buildLayoutFromEditorLayout = (layout: any, parentOrientation?: number): WindowLayout => {
                // 如果是简单组（没有嵌套groups）
                if (!layout.groups || layout.groups.length === 0 || 
                    (layout.groups.length === 1 && (!layout.groups[0].groups || layout.groups[0].groups.length === 0))) {
                    // 这是一个叶子节点
                    const viewColumn = groups[groupIndex]?.viewColumn;
                    groupIndex++;
                    
                    return {
                        type: 'leaf',
                        buffers: groupBuffers.get(viewColumn) || [],
                        size: layout.size // 保持VSCode提供的比例值
                    };
                }

                // 处理复杂布局
                // VSCode使用0表示水平排列（垂直分割），1表示垂直排列（水平分割）
                // 每一层的方向与其父层相反
                let splitType: 'vsplit' | 'hsplit';
                
                // 如果parentOrientation未定义（根层次），直接使用layout.orientation
                // 否则每一层的分割方式与父层相反
                if (parentOrientation === undefined) {
                    splitType = layout.orientation === 0 ? 'vsplit' : 'hsplit';
                } else {
                    splitType = parentOrientation === 0 ? 'hsplit' : 'vsplit';
                }
                
                const children: WindowLayout[] = [];
                
                // 计算总尺寸，用于计算比例
                const totalSize = layout.groups.reduce((sum: number, group: any) => sum + (group.size || 1), 0);
                
                for (const group of layout.groups) {
                    // 递归处理子布局，将当前层的orientation传递给子层
                    const child = buildLayoutFromEditorLayout(group, layout.orientation);
                    
                    // 计算比例值
                    if (group.size !== undefined) {
                        child.size = group.size / totalSize;
                    }
                    
                    children.push(child);
                }
                
                return {
                    type: splitType,
                    children,
                    size: layout.size // 保持VSCode提供的比例值
                };
            };
            
            return buildLayoutFromEditorLayout(editorLayout);
            
        } catch (error) {
            this.log(`Failed to build layout from editor layout: ${error}`);
            
            // 回退到简单布局
            // 默认使用垂直分割
            const children: WindowLayout[] = [];
            
            // 计算每个视图的均等比例
            const ratio = 1 / groupBuffers.size;
            
            for (const [viewColumn, buffers] of groupBuffers.entries()) {
                children.push({
                    type: 'leaf',
                    buffers,
                    size: ratio // 使用均等比例
                });
            }
            
            return {
                type: 'vsplit',
                children
            };
        }
    }

    private async handleBufferChange(data: { path: string }): Promise<void> {
        if (!this.config.autoReload) {
            return;
        }

        // Ignore special files
        if (this.shouldIgnoreFile(data.path)) {
            return;
        }

        const uri = vscode.Uri.file(data.path);
        try {
            const doc = await vscode.workspace.openTextDocument(uri);
            await doc.save();
        } catch (err) {
            this.log(`Failed to reload document: ${err}`);
        }
    }

    /**
     * 比较两个窗口布局是否有实质性变化
     * @param oldLayout 旧的窗口布局
     * @param newLayout 新的窗口布局
     * @returns 布尔值，表示是否有非忽略窗口的变动
     */
    private hasSignificantChanges(oldLayout: WindowLayout | null, newLayout: WindowLayout): boolean {
        if (!oldLayout) {
            // 第一次比较，认为有变化
            return true;
        }

        // 比较分割类型
        if (oldLayout.type !== newLayout.type) {
            this.log("Split type changed");
            return true;
        }

        // 提取所有非忽略文件的缓冲区
        const extractNonIgnoredBuffers = (layout: WindowLayout): TabInfo[] => {
            const result: TabInfo[] = [];
            
            const processNode = (node: WindowLayout) => {
                if (node.type === 'leaf' && node.buffers) {
                    // 过滤非忽略文件
                    const nonIgnoredBuffers = node.buffers.filter(buffer => !this.shouldIgnoreFile(buffer.path));
                    result.push(...nonIgnoredBuffers);
                } else if (node.children) {
                    // 递归处理子节点
                    node.children.forEach(processNode);
                }
            };
            
            processNode(layout);
            return result;
        };

        const oldBuffers = extractNonIgnoredBuffers(oldLayout);
        const newBuffers = extractNonIgnoredBuffers(newLayout);

        // 比较缓冲区数量
        if (oldBuffers.length !== newBuffers.length) {
            this.log(`Buffer count changed: ${oldBuffers.length} -> ${newBuffers.length}`);
            return true;
        }

        // 创建文件路径到缓冲区的映射，以便快速查找
        const oldBufferMap = new Map<string, TabInfo>();
        oldBuffers.forEach(buffer => {
            oldBufferMap.set(buffer.path, buffer);
        });

        // 检查每个新缓冲区是否存在变化
        for (const newBuffer of newBuffers) {
            const oldBuffer = oldBufferMap.get(newBuffer.path);
            
            // 新添加的文件
            if (!oldBuffer) {
                this.log(`New file added: ${newBuffer.path}`);
                return true;
            }
            
            // 激活状态变化
            if (oldBuffer.active !== newBuffer.active) {
                this.log(`Active state changed for ${newBuffer.path}: ${oldBuffer.active} -> ${newBuffer.active}`);
                return true;
            }
            
            // 视图状态变化 (光标位置或滚动位置变化)
            if (oldBuffer.viewState && newBuffer.viewState) {
                const oldVS = oldBuffer.viewState;
                const newVS = newBuffer.viewState;
                
                // 光标位置变化
                if (oldVS.cursor.line !== newVS.cursor.line || 
                    oldVS.cursor.character !== newVS.cursor.character) {
                    this.log(`Cursor position changed for ${newBuffer.path}`);
                    return true;
                }
                
                // 滚动位置变化
                if (oldVS.scroll.topLine !== newVS.scroll.topLine || 
                    oldVS.scroll.bottomLine !== newVS.scroll.bottomLine) {
                    this.log(`Scroll position changed for ${newBuffer.path}`);
                    return true;
                }
            } else if (oldBuffer.viewState !== newBuffer.viewState) {
                // 一个有视图状态而另一个没有
                this.log(`View state existence changed for ${newBuffer.path}`);
                return true;
            }
        }
        
        // 检查窗口结构变化
        const compareStructure = (oldNode: WindowLayout, newNode: WindowLayout): boolean => {
            if (oldNode.type !== newNode.type) {
                return false;
            }
            
            if (oldNode.children && newNode.children) {
                if (oldNode.children.length !== newNode.children.length) {
                    return false;
                }
                
                for (let i = 0; i < oldNode.children.length; i++) {
                    if (!compareStructure(oldNode.children[i], newNode.children[i])) {
                        return false;
                    }
                }
                
                return true;
            }
            
            return true;
        };
        
        if (!compareStructure(oldLayout, newLayout)) {
            this.log("Window structure changed");
            return true;
        }
        
        return false;
    }

    public syncEditorGroups(): void {
        if (!this.client || this.isProcessingNeovimMessage()) {
            return;
        }

        this.getEditorGroupsInfo().then(layout => {
            // 只发送有效的布局信息
            if (layout.type === 'leaf' && !layout.buffers?.length && !(layout.children?.length)) {
                return; // 空布局不发送
            }
            
            // 检查与上次布局相比是否有重要变化
            if (this.hasSignificantChanges(this.lastWindowLayout, layout)) {
                // 只有当有重要变化时才发送消息
                this.sendMessage({
                    type: 'editor_group',
                    data: layout
                });
                
                // 更新上次布局状态
                this.lastWindowLayout = JSON.parse(JSON.stringify(layout));
            }
        });
    }

    public syncBuffer(filePath: string): void {
        if (!this.client || this.isProcessingNeovimMessage()) {
            return;
        }

        // Ignore special files
        if (this.shouldIgnoreFile(filePath)) {
            return;
        }

        const currentTime = Date.now();
        const lastSyncTime = this.lastSyncedFiles.get(filePath) || 0;
        
        // 如果该文件最近已经同步过（至少1秒内），则跳过
        if (currentTime - lastSyncTime < 1000) {
            this.log(`Skipping sync for recently synced file: ${filePath}`);
            return;
        }
        
        // 更新同步时间
        this.lastSyncedFiles.set(filePath, currentTime);
        
        // 清理过期的文件记录（保持映射表大小合理）
        if (this.lastSyncedFiles.size > 100) {
            const expireTime = currentTime - 60000; // 删除1分钟前的记录
            for (const [path, time] of this.lastSyncedFiles.entries()) {
                if (time < expireTime) {
                    this.lastSyncedFiles.delete(path);
                }
            }
        }

        this.sendMessage({
            type: 'buffer_change',
            data: {
                path: filePath
            }
        });
    }

    private sendMessage(message: Message): void {
        if (!this.client) {
            return;
        }

        try {
            const messageStr = JSON.stringify(message) + '\0';
            this.log('Sending message: ' + messageStr);
            this.client.write(messageStr);
        } catch (err) {
            this.log('Failed to send message: ' + err);
        }
    }

    private restart(): void {
        if (this.client) {
            this.client.end();
            this.client = null;
        }
        
        // 清除所有缓存
        this.lastWindowLayout = null;
        this.lastSyncedFiles.clear();
        this.messageBuffer = '';
        
        this.connect();
    }

    public dispose(): void {
        if (this.client) {
            this.client.end();
            this.client = null;
        }
        
        // 清除所有缓存
        this.lastWindowLayout = null;
        this.lastSyncedFiles.clear();
        this.messageBuffer = '';
        
        for (const disposable of this.disposables) {
            disposable.dispose();
        }
        this.disposables = [];
    }

    private log(message: string) {
        const timestamp = new Date().toISOString();
        this.outputChannel.appendLine(`[${timestamp}] ${message}`);
    }

    public isProcessingNeovimMessage(): boolean {
        return this.isHandlingNeovimMessage;
    }
} 