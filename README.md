  
## *This is Justin_Green_MCU*   
          
<img width="1662" height="1178" alt="image" src="https://github.com/user-attachments/assets/6666a6a2-c636-4532-8aee-61104647fcb9" />

*v3.4.x FPGA device map*  

<img width="2135" height="1272" alt="image" src="https://github.com/user-attachments/assets/ca86bafc-2ad9-47ff-83d0-d39bc1072fe2" />  
   
*v3.4.x implemented schematic (CPU unfolded)*

> >
>    𝐃𝐎 𝐘𝐎𝐔 𝐋𝐈𝐊𝐄 𝐆𝐑𝐄𝐄𝐍𝐄𝐑𝐈𝐄𝐒 —— 你喜欢看绿油油的𝐒𝐜𝐡𝐞𝐦𝐚𝐭𝐢𝐜吗

>  RTL 文件 —— 本人独立设计  
>  testbench测试文件 / 初始 rom-hex (或RTOS) / 说明文档 / 上层工具链（部分版本） —— AI 辅助生成
> >
>  项目随进度更新
  
> “~我只是个搓绿化带的”
>
   
    
      
## 技术概述（基于当前v3.4.x）：
  
### CPU部分：
  
- 基于自拟RISC指令集的8位架构（8位ALU+8位快速寄存器）；工作频率50MHz，极限频率66.67MHz；工作频率下理论最大算力50MIPS
  
- 自拟 6_bit_opcode ISA，共 (32 + 1伪 + 19自动压缩) 条指令；指令设计参考RISC-V整数指令集，基础指令32位，压缩指令16位，指令汇编器端自动压缩，硬件自动解码；支持控制、ALU、访存、IRET、HALT不可逆停机；详见说明文档-指令集说明
  
- 4 级流水线 (IF / ID <Unzip + Shift + ID> / EX / WB) 架构；两级前送 + 旁路消除 RAW 冒险；跳转/中断冲刷，流水线空窗保护
  
- (32KB) 32位ROM，（256B）8位快速寄存器，（512B）16位返回栈专用寄存器；RPU可编程快速寄存器任务映射；硬件返回栈深 255，寄存器组映射栈指针，满栈/空栈保护 (JAL/JALR)
  
- 硬件中断控制器，支持 6 路外部中断源 (UART/Timer/GPIO1/2/DMA/I2C)；支持软中断，可编程中断优先级嵌套，可初始化编程向量表，初始中断屏蔽，IRET 恢复断点

<img width="1215" height="766" alt="image" src="https://github.com/user-attachments/assets/4d252ecb-0eb3-433f-8d99-fc2cd8e96335" />  

*instruction_file overview*

    
### 外设部分：  
  
- 自拟 16 位总线，16位addr + 8位data + 4位signal（目前仅占用1位）；MMIO 挂载RAM、UART (Dual FIFO)、Timer、DMA、GPIO、I2C
  
- rst硬件消抖：双边沿检测，缓冲同步时钟信号，微计时器延时消抖
  
- 总线仲裁控制器：总控总线-CPU-DMA通路，联合中断控制器管理可编程中断屏蔽、优先级
  
- UART：工作频率115200Hz；收发双缓冲，Busy信号映射到快速寄存器；支持中断、轮询双模式
  
- 单输出I2C：可编程配置频率模式100KHz、400KHz、1MHz；可编程应答检测；发送缓冲，Busy信号映射到快速寄存器；支持报错中断、轮询（针对OLED屏幕调试中）

- RAM：共28KB（12KB直连 + 16KB分片拓展）；直连寄存器单片独立地址映射，STORE耗时1时钟沿，LOAD耗时2时钟沿；分片寄存器访问前需下达片选指令，片选后访问耗时同上
  
- DMA：搬运缓冲池；可读写16位搬运计数器，可写16位超时计数器；分片RAM单端限制，支持自动片选；支持中断

- TIMER：32位可编程计时器；两路共频独立可编程占空比PWM输出；支持指令清空读数；支持开关中断（和总线控制仲裁器中断屏蔽功能重叠）

- GPIO组：8路可编程复用型GPIO_PIN；支持IN、OUT、IN_IRQ（每4路共用1中断信号）、UART（tx/rx）、I2C（scl/sda）、PWM

### 软件生态（AIGC）：

- 基于Python语言的.asm转.hex汇编器；支持自动指令检测压缩，支持语义识别跳转指令纠错，支持宏；可告警、报错输出 (适装当前及部分早期版本，不建议跨版本使用)

- 搭载抢占式RTOS内核（v2.3起，v2.2为协作式RTOS），支持任务调用栈分区核基于硬件中断的抢占调度，类Shell操作界面

<img width="1691" height="662" alt="image" src="https://github.com/user-attachments/assets/cdad04f8-7fa2-4b35-8aab-1d21855e589c" />

<img width="1701" height="532" alt="image" src="https://github.com/user-attachments/assets/567d3805-c8e1-4cb2-b91e-c06600d71ef1" />
   
*v3.4.x version MCU running RTOS system with UART in/output*
  
### 备注：
  
- EDA：Xilinx™ Vivado 2019.1 
- FPGA芯片: Xilinx™ Zynq-7000 xc7z010clg400-1  
- 开发板: Microphase™ Z-7 Lite Motherboard  
- 若使用，请在RTL文件中重定向ins_rom.hex(及data.hex)的加载路径
> 注: 目前v2.2（RTOS内核植入）以前的内容都缺乏充分debug；上板方法不做说明

