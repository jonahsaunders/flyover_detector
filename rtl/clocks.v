module clocks (
    input wire ref_clk,
    output wire clk, mem_clk, locked
);
    // MS5351 O0 supplies 49.152 MHz. A 16x VCO (786.432 MHz) gives
    // synchronous 1x outputs, with the SDRAM clock shifted by 180 degrees.
    rPLL #(
        .DEVICE("GW2A-18C"), .FCLKIN("49.152"),
        .IDIV_SEL(0), .FBDIV_SEL(0), .ODIV_SEL(16),
        .PSDA_SEL("1000"), .DUTYDA_SEL("1000")
    ) audio_pll (
        .CLKIN(ref_clk), .CLKOUT(clk), .CLKOUTP(mem_clk), .LOCK(locked),
        .CLKFB(1'b0), .RESET(1'b0), .RESET_P(1'b0),
        .FBDSEL(6'b0), .IDSEL(6'b0), .ODSEL(6'b0), .PSDA(4'b0),
        .DUTYDA(4'b0), .FDLY(4'b0), .CLKOUTD(), .CLKOUTD3()
    );
endmodule
