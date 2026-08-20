<img width="2117" height="1277" alt="image" src="https://github.com/user-attachments/assets/6c621854-13a0-4f1b-93f1-f8839b198f45" />

> >
>    𝐃𝐎 𝐘𝐎𝐔 𝐋𝐈𝐊𝐄 𝐆𝐑𝐄𝐄𝐍𝐄𝐑𝐈𝐄𝐒        你喜欢看绿油油的𝐒𝐜𝐡𝐞𝐦𝐚𝐭𝐢𝐜吗

>  RTL 文件 —— 本人独立设计  
>  testbench测试文件 / 初始 rom-hex (或RTOS) / 说明文档 / 上层工具链（部分版本） —— AI 辅助生成
> >
>  项目随进度更新

> “~我只是个搓绿化带的”
>  
  
  
- 哈佛架构，自拟 6-bit opcode 可压缩（32bit/16bit-compressed) ISA ，(32 + 1伪 + 19自动压缩) 条指令，支持控制、ALU、访存、IRET，RISC 风格，8位通用寄存器和ALU
- 4 级流水线 (IF/ID/EX/WB)，两级前送+旁路消除 RAW 冒险，分支/中断 1 拍冲刷
- (32KB)ROM，256B快速寄存器，自拟 16 位总线，MMIO 挂载(12 + 16 KB)RAM、UART (Dual FIFO)、Timer、8 位可动态配置 GPIO(支持UART、IN、OUT、IRQ_IN、PWM)
- 硬件中断控制器，支持 5 路外部中断源 (UART/Timer/GPIO1/2/DMA)，软中断，可编程中断优先级嵌套，可初始化编程向量表 + IRET 恢复断点
- 硬件返回栈深 255 (非通用寄存器)，寄存器组映射栈指针，满栈/空栈保护 (JAL/JALR)，flush 条件化
- 支持 HALT 指令不可逆停机，rst 硬件消抖，初始化复位
- 部分版本带有基于 Python 的 asm 转 hex 汇编器 (仅支持对应版本)，自v2.2开始植入RTOS内核（协作/抢占式）
>
- EDA：Xilinx™ Vivado 2019.1  
- FPGA芯片: Xilinx™ Zynq-7000 xc7z010clg400-1  
- 开发板: Microphase™ Z-7 Lite Motherboard  
- 若使用，请在RTL文件中重定向ins_rom.hex(及data.hex)的加载路径
> 注: 目前v2.2(RTOS内核植入)以前的内容都缺乏充分debug

