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
    type: 'leaf' | 'vsplit' | 'hsplit' | 'auto';
    buffers?: TabInfo[];
    children?: WindowLayout[];
    size?: number;
}

interface Message {
    type: 'editor_group' | 'buffer_change' | 'view_change';
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
                case 'view_change':
                    await this.handleViewChange(message.data as { path: string; viewState: ViewState });
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
            let activeEditor: { groupIndex: number, buffer: TabInfo } | null = null;

            // 第一遍：打开所有非激活的标签页
            for (let i = 0; i < vscodeGroups.length; i++) {
                const buffers = allBuffers[i];
                if (!buffers) continue;

                for (const buffer of buffers) {
                    try {
                        if (this.shouldIgnoreFile(buffer.path)) {
                            continue;
                        }

                        if (buffer.active) {
                            activeEditor = { groupIndex: i, buffer };
                            continue;
                        }

                        const uri = vscode.Uri.file(buffer.path);
                        const doc = await vscode.workspace.openTextDocument(uri);
                        await vscode.window.showTextDocument(doc, {
                            viewColumn: vscodeGroups[i].viewColumn,
                            preview: false,
                            preserveFocus: true // 所有非激活的标签页都设置 preserveFocus: true
                        });

                        if (buffer.viewState) {
                            const editor = vscode.window.visibleTextEditors.find(
                                e => e.document.uri.fsPath === uri.fsPath && 
                                     e.viewColumn === vscodeGroups[i].viewColumn
                            );
                            if (editor) {
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
                        this.log(`Failed to handle buffer ${buffer.path}: ${error}`);
                    }
                }
            }

            // 第二遍：最后打开激活的标签页
            if (activeEditor) {
                try {
                    const uri = vscode.Uri.file(activeEditor.buffer.path);
                    const doc = await vscode.workspace.openTextDocument(uri);
                    await vscode.window.showTextDocument(doc, {
                        viewColumn: vscodeGroups[activeEditor.groupIndex].viewColumn,
                        preview: false,
                        preserveFocus: false // 激活的标签页设置 preserveFocus: false
                    });

                    if (activeEditor.buffer.viewState) {
                        const editor = vscode.window.activeTextEditor;
                        if (editor && editor.document.uri.fsPath === uri.fsPath) {
                            const position = new vscode.Position(
                                activeEditor.buffer.viewState.cursor.line,
                                activeEditor.buffer.viewState.cursor.character
                            );
                            editor.selection = new vscode.Selection(position, position);
                            editor.revealRange(
                                new vscode.Range(
                                    activeEditor.buffer.viewState.scroll.topLine, 0,
                                    activeEditor.buffer.viewState.scroll.bottomLine, 0
                                ),
                                vscode.TextEditorRevealType.InCenter
                            );
                        }
                    }
                } catch (error) {
                    this.log(`Failed to handle active buffer ${activeEditor.buffer.path}: ${error}`);
                }
            }
        } else {
            // 如果 editor group 数量不一致，按照原来的逻辑重建布局
            if (layout.type === 'leaf') {
                // Handle leaf node
                for (const buffer of layout.buffers || []) {
                    try {
                        if (this.shouldIgnoreFile(buffer.path)) {
                            continue;
                        }

                        const uri = vscode.Uri.file(buffer.path);
                        const doc = await vscode.workspace.openTextDocument(uri);
                        await vscode.window.showTextDocument(doc, {
                            viewColumn,
                            preview: false,
                            preserveFocus: !buffer.active
                        });

                        if (buffer.viewState) {
                            const editor = vscode.window.activeTextEditor;
                            if (editor && editor.document.uri.fsPath === uri.fsPath) {
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
                        this.log(`Failed to handle buffer ${buffer.path}: ${error}`);
                    }
                }
            } else {
                // Handle split node
                for (let i = 0; i < (layout.children || []).length; i++) {
                    const child = layout.children![i];
                    const nextColumn = layout.type === 'vsplit' 
                        ? viewColumn + i 
                        : viewColumn;
                    await this.applyWindowLayout(child, nextColumn);
                }
            }
        }
    }

    private async getEditorGroupsInfo(): Promise<WindowLayout> {
        const groups = vscode.window.tabGroups.all;
        if (groups.length === 0) {
            return {
                type: 'auto',
                children: []
            };
        }

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

                if (editor) {
                    // 如果编辑器可见，使用当前状态
                    viewState = {
                        cursor: {
                            line: editor.selection.active.line,
                            character: editor.selection.active.character
                        },
                        scroll: {
                            topLine: editor.visibleRanges[0]?.start.line ?? 0,
                            bottomLine: editor.visibleRanges[0]?.end.line ?? 0
                        }
                    };
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

        return {
            type: 'auto',
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

    private async handleViewChange(data: { path: string; viewState: ViewState }): Promise<void> {
        // Ignore special files
        if (this.shouldIgnoreFile(data.path)) {
            return;
        }

        const uri = vscode.Uri.file(data.path);
        const editor = vscode.window.visibleTextEditors.find(
            editor => editor.document.uri.fsPath === uri.fsPath
        );

        if (editor) {
            this.log(`Updating view state for ${data.path}`);
            
            // Update cursor position
            const position = new vscode.Position(
                data.viewState.cursor.line,
                data.viewState.cursor.character
            );
            editor.selection = new vscode.Selection(position, position);

            // Update scroll position
            editor.revealRange(
                new vscode.Range(
                    data.viewState.scroll.topLine, 0,
                    data.viewState.scroll.bottomLine, 0
                ),
                vscode.TextEditorRevealType.InCenter
            );
        }
    }

    public syncEditorGroups(): void {
        if (!this.client || this.isProcessingNeovimMessage()) {
            return;
        }

        this.getEditorGroupsInfo().then(layout => {
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

    public syncViewState(filePath: string): void {
        if (!this.client || this.isProcessingNeovimMessage()) {
            return;
        }

        // Ignore special files
        if (this.shouldIgnoreFile(filePath)) {
            return;
        }

        const editor = vscode.window.visibleTextEditors.find(
            e => e.document.uri.fsPath === filePath
        );

        if (editor) {
            this.sendMessage({
                type: 'view_change',
                data: {
                    path: filePath,
                    viewState: {
                        cursor: {
                            line: editor.selection.active.line,
                            character: editor.selection.active.character
                        },
                        scroll: {
                            topLine: editor.visibleRanges[0]?.start.line ?? 0,
                            bottomLine: editor.visibleRanges[0]?.end.line ?? 0
                        }
                    }
                }
            });
        }
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