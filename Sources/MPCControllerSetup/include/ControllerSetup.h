#ifndef MPC_CONTROLLER_SETUP_H
#define MPC_CONTROLLER_SETUP_H
int controller_initialize(int pad_bank, int qlink_bank);
void controller_shutdown(void);
int controller_refresh_banks(int pad_bank, int qlink_bank);
int controller_send_qlink_value(int knob, int value);
int controller_set_button_light(int note, int value);
#endif
