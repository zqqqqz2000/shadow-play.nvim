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

        // 创建包含所有buffer信息的子节点
        const children: WindowLayout[] = [];
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

                // 首先尝试从 visibleTextEditors 获取编辑器
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
                        
                        this.log(`Got view state for active editor ${uri.fsPath}: cursor(${viewState.cursor.line},${viewState.cursor.character}), scroll(${viewState.scroll.topLine},${viewState.scroll.bottomLine})`);
                    }
                }

                buffers.push({
                    path: uri.fsPath,
                    active: tab.isActive,
                    viewState
                });
            }

            if (buffers.length > 0) {
                children.push({
                    type: 'leaf',
                    buffers,
                    size: 1 / groups.length
                });
            }
        }

        // 如果只有一个子节点，直接返回
        if (children.length <= 1) {
            return children[0] || { type: 'leaf', buffers: [] };
        }

        // 判断分割类型 - 从VS Code的布局中推断
        // 默认使用垂直分割，因为这是最常见的多编辑器布局
        let splitType: 'vsplit' | 'hsplit' = 'vsplit';
        
        try {
            // 尝试获取VS Code的编辑器布局
            const editorLayout = await vscode.commands.executeCommand('vscode.getEditorLayout') as any;
            this.log(`Editor layout: ${JSON.stringify(editorLayout)}`);
            if (editorLayout && editorLayout.orientation !== undefined) {
                // VS Code使用0表示水平排列（垂直分割），1表示垂直排列（水平分割）
                splitType = editorLayout.orientation === 0 ? 'vsplit' : 'hsplit';
            }
        } catch (error) {
            this.log(`Failed to get editor layout: ${error}`);
        }

        return {
            type: splitType,
            children
        };
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

    public syncEditorGroups(): void {
        if (!this.client || this.isProcessingNeovimMessage()) {
            return;
        }

        this.getEditorGroupsInfo().then(layout => {
            // 只发送有效的布局信息
            if (layout.type === 'leaf' && !layout.buffers?.length && !(layout.children?.length)) {
                return; // 空布局不发送
            }
            
            this.sendMessage({
                type: 'editor_group',
                data: layout
            });
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
        this.connect();
    }

    public dispose(): void {
        if (this.client) {
            this.client.end();
            this.client = null;
        }
        
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