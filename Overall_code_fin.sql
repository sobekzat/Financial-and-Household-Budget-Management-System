-- triggers 

create or replace trigger trg_account_balance_update
after insert or update on transactions
for each row
declare
    v_sign number;
begin
    if :new.type = 'INCOME' then
        v_sign := 1;
    else
        v_sign := -1;
    end if;

    update financial_accounts
    set balance = balance + (:new.amount * v_sign)
    where account_id = :new.account_id;
end;
/

create or replace trigger trg_auto_transaction_date
before insert on transactions
for each row
begin
    if :new.date_ is null then
        :new.date_ := sysdate;
    end if;
end;


create or replace trigger trg_savings_check
before update on savings
for each row
begin
    if :new.current_amount > :old.goal_amount then
        raise_application_error(
            -20001,
            'current savings cannot exceed goal amount!'
        );
    end if;
end;

create sequence notifications_seq
start with 1
increment by 1
nocache
nocycle;

create or replace trigger notify_low_balance
after update of balance on financial_accounts
for each row
declare
    v_threshold number := 50; 
    v_msg varchar2(4000);
begin
    if :new.balance is not null 
        and :new.balance < v_threshold 
        and nvl(:old.balance,0) >= v_threshold then
        
        v_msg := 'account balance ' || :new.account_id || ' low: ' || :new.balance;
        
        insert into notifications(
            notification_id, 
            user_id, 
            message, 
            type, 
            created_at, 
            is_read
        )
        values (
            notifications_seq.nextval, 
            :new.user_id, 
            v_msg, 
            'low_balance', 
            sysdate, 
            0
        );
    end if;
exception
    when others then
        null;
end;


create or replace trigger high_expense
before insert or update on transactions
for each row
begin
    if :new.amount > 10000 then
        :new.description := 'high expense: ' || :new.description;
    end if;
end;



-- packages & exceptions 

create or replace package pkg_budget as
    e_over_budget exception;

    function get_category_monthly_total(
        p_household_id number,
        p_category_id  number,
        p_year number,
        p_month number
    ) return number;

    procedure check_budget_limit(
        p_household_id number,
        p_category_id  number,
        p_year number,
        p_month number
    );
end pkg_budget;


create or replace package body pkg_budget as

    function get_category_monthly_total(
        p_household_id number,
        p_category_id  number,
        p_year number,
        p_month number
    ) return number
    is
        v_total number := 0;
    begin
        select nvl(sum(e.amount),0)
        into v_total
        from expenses e
        join users u on e.user_id = u.user_id
        where u.household_id = p_household_id
          and e.category_id = p_category_id
          and extract(year from e.expense_date) = p_year
          and extract(month from e.expense_date) = p_month;

        return v_total;
    end;

    procedure check_budget_limit(
        p_household_id number,
        p_category_id  number,
        p_year number,
        p_month number
    )
    is
        v_limit number;
        v_spent number;
    begin
        select monthly_limit into v_limit
        from budget_goals
        where household_id = p_household_id
          and category_id = p_category_id;

        v_spent := get_category_monthly_total(p_household_id, p_category_id, p_year, p_month);

        if v_spent > v_limit then
            raise e_over_budget;
        end if;
    end;

end pkg_budget;


create or replace package check_and_delete_inactive as
    e_deactivation_error exception; 
    pragma exception_init(e_deactivation_error, -20001); 
    function user_inactive_check (p_user_id in number) return boolean;
    procedure deactivate_stale_users;
end check_and_delete_inactive;


create or replace package body check_and_delete_inactive as
    function user_inactive_check(p_user_id in number) return boolean is
        v_registration_date date;
        v_last_transaction date;
        c_registered_days constant number := 365;
        c_no_transaction_days constant number := 180;
    begin
        select registration_date into v_registration_date
        from users
        where user_id = p_user_id and rownum = 1;

        if sysdate - v_registration_date < c_registered_days then
            return false;
        end if;

        select max(t.date_) into v_last_transaction
        from transactions t
        join financial_accounts fa on t.account_id = fa.account_id
        where fa.user_id = p_user_id;

        if v_last_transaction is null or sysdate - v_last_transaction > c_no_transaction_days then
            return true;
        else
            return false;
        end if;

    exception
        when no_data_found then
            return true; 
    end user_inactive_check;

    procedure deactivate_stale_users is
        v_deactivated_count number := 0;
    begin
        dbms_output.put_line('checking for stale users...');
        for rec_user in (select user_id, first_name from users) loop
            begin 
                if user_inactive_check(rec_user.user_id) then
                    dbms_output.put_line('attempting deactivation for: ' || rec_user.first_name);
                    update financial_accounts
                    set is_active = 'false' 
                    where user_id = rec_user.user_id
                    and is_active = 'true'; 

                    v_deactivated_count := v_deactivated_count + sql%rowcount;
                end if;
            
            exception
                when others then
                    dbms_output.put_line('!!! error for user ' || rec_user.first_name || ': ' || sqlerrm);
            end;
        end loop;

        dbms_output.put_line('total accounts successfully deactivated: ' || v_deactivated_count);
        commit;

    exception
        when others then
            rollback; 
            raise_application_error(-20001, 'critical error during stale user deactivation: ' || sqlerrm); 
    end deactivate_stale_users;

end check_and_delete_inactive;


create or replace package provider_check_pkg as
    function provider_exists(p_provider in varchar2) return varchar2;
    procedure display_provider_accounts(p_provider in varchar2);
end provider_check_pkg;


create or replace package body provider_check_pkg as

    function provider_exists(p_provider in varchar2) return varchar2 is
        v_count number;
    begin
        select count(*)
        into v_count
        from financial_accounts
        where provider = p_provider;

        if v_count > 0 then
            return 'provider exists';
        else
            return 'provider does not exist';
        end if;

    exception
        when others then
            return 'error checking provider: ' || sqlerrm;
    end provider_exists;

    procedure display_provider_accounts(p_provider in varchar2) is
        v_message varchar2(100);
    begin
        v_message := provider_exists(p_provider);

        if v_message = 'provider does not exist' then
            raise_application_error(-20010, 'provider ' || p_provider || ' does not exist.');
        elsif v_message like 'error%' then
            dbms_output.put_line(v_message);
            return;
        end if;

        for rec in (
            select user_id, card_number, balance, is_active
            from financial_accounts
            where provider = p_provider
        ) loop
            dbms_output.put_line('user_id: ' || rec.user_id 
                                 ', card_number: ' || rec.card_number 
                                 ', balance: ' || rec.balance 
                                 ', is_active: ' || rec.is_active);
        end loop;

    exception
        when others then
            dbms_output.put_line('error displaying provider accounts: ' || sqlerrm);
    end display_provider_accounts;

end provider_check_pkg;



-- cursor & records

create or replace procedure proc_top_categories(
    p_user_id number,
    p_year number,
    p_month number
)
is
    cursor c_top is
        select category_id, sum(amount) as total_amount
        from expenses
        where user_id = p_user_id
          and extract(year from expense_date) = p_year
          and extract(month from expense_date) = p_month
        group by category_id
        order by total_amount desc
        fetch first 5 rows only;

    v_rec c_top%rowtype;
begin
    dbms_output.put_line('--- top 5 categories for user ' || p_user_id || ' in ' || p_year || '-' || p_month || ' ---');
    open c_top;
    loop
        fetch c_top into v_rec;
        exit when c_top%notfound;

        dbms_output.put_line(
            'category id: ' || v_rec.category_id || 
            ' | total spent: ' || v_rec.total_amount
        );
    end loop;
    close c_top;
end;



create or replace procedure proc_user_cashflow(
    p_user_id number,
    p_year number
)
is
    cursor c_tr is
        select type, amount
        from transactions
        where account_id in (
            select account_id 
            from financial_accounts 
            where user_id = p_user_id
        )
        and extract(year from date_) = p_year;

    v_type transactions.type%type;
    v_amount number;
    v_income number := 0;
    v_expense number := 0;

begin
    open c_tr;
    loop
        fetch c_tr into v_type, v_amount;
        exit when c_tr%notfound;

        if v_type = 'INCOME' then
            v_income := v_income + v_amount;
        else
            v_expense := v_expense + v_amount;
        end if;
    end loop;
    close c_tr;

    dbms_output.put_line('--- cashflow for user ' || p_user_id || ' in ' || p_year || ' ---');
    dbms_output.put_line('total income: ' || v_income);
    dbms_output.put_line('total expenses: ' || v_expense);
    dbms_output.put_line('net cashflow: ' || (v_income - v_expense));
end;

declare
    type rec_bills is record (
        bill_id   bills.bill_id%type,
        bill_type bills.bill_type%type,
        amount    bills.amount%type,
        end_date  bills.billing_period_end%type
    );

    v_rec rec_bills;

    cursor cur_unpaid_bills is
        select bill_id, bill_type, amount, billing_period_end
        from bills
        where is_paid = 'false';
begin
    dbms_output.put_line('--- unpaid bills ---');
    open cur_unpaid_bills;

    loop
        fetch cur_unpaid_bills into v_rec;
        exit when cur_unpaid_bills%notfound;

        dbms_output.put_line(
            'bill id: '  v_rec.bill_id 
            ' | bill_type: '||  v_rec.bill_type ||
            ' | amount: '  || v_rec.amount || 
            ' | end_date: ' || v_rec.end_date ||
        );
    end loop;

    close cur_unpaid_bills;
end;

exception
    when no_data_found then
        dbms_output.put_line('household ' || p_household_id || ' not found.');
    when others then
        dbms_output.put_line('an error occurred: ' || sqlerrm);
end;


declare
    type rec_user_expenses is record (
        user_id         users.user_id%type,
        name            users.first_name%type,
        total_expenses  number
    );

    v_rec rec_user_expenses;

    cursor cur_expenses is
        select u.user_id,
               u.first_name,
               nvl(sum(e.amount), 0) as total_expenses
        from users u
        left join expenses e on u.user_id = e.user_id
        group by u.user_id, u.first_name;
begin
    dbms_output.put_line('--- total expenses by user ---');
    open cur_expenses;

    loop
        fetch cur_expenses into v_rec;
        exit when cur_expenses%notfound;

        
        dbms_output.put_line(
            'user: ' || v_rec.name ||  
            ' | total expenses: ' || v_rec.total_expenses
        );
    end loop;

    close cur_expenses;
end;


declare
    type rec_bills is record (
        bill_id     bills.bill_id%type,
        bill_type   bills.bill_type%type,
        amount      bills.amount%type,
        end_date    bills.billing_period_end%type
    );

    v_rec rec_bills;

    cursor cur_unpaid_bills is
        select bill_id, bill_type, amount, billing_period_end
        from bills
        where is_paid = 'false';
begin
    dbms_output.put_line('--- unpaid bills ---');
    open cur_unpaid_bills;

    loop
        fetch cur_unpaid_bills into v_rec;
        exit when cur_unpaid_bills%notfound;

        
          dbms_output.put_line(
            'bill id: ' || v_rec.bill_id ||  
            ' | bill_type: ' || v_rec.bill_type || 
            ' | amount: ' || v_rec.amount || 
            ' | end_date: ' || v_rec.end_date);
    end loop;

    close cur_unpaid_bills;
end;


-- functions & procedures

create or replace function fn_get_monthly_expenses(
    p_user_id  in number,
    p_year     in number,
    p_month    in number
) return number
is
    v_total number := 0;
begin
    select nvl(sum(amount), 0)
    into v_total
    from expenses
    where user_id = p_user_id
      and extract(year from expense_date) = p_year
      and extract(month from expense_date) = p_month;

    return v_total;
end;


create or replace function fn_savings_progress(
    p_user_id  in number,
    p_saving_id in number
) return number
is
    v_goal number;
    v_current number;
begin
    select goal_amount, current_amount
    into v_goal, v_current
    from savings
    where saving_id = p_saving_id
      and user_id = p_user_id;

    if v_goal = 0 then
        return 0;
    end if;

    return round((v_current / v_goal) * 100, 2);
end;


create or replace function calculate_total_income(p_user_id number) return number is
    v_total_income number;
begin
    select nvl(sum(amount), 0)
    into v_total_income
    from income_sources
    where user_id = p_user_id;

    return v_total_income;
end;


create or replace procedure show_total_income(p_user_id number)
is
    v_income number;
    v_frequency varchar2(50);
begin
    v_income := calculate_total_income(p_user_id);
    select frequency
    into v_frequency
    from (
        select frequency
        from income_sources
        where user_id = p_user_id)
    where rownum = 1;

    dbms_output.put_line('--- total income details for user ' || p_user_id || ' ---');
    dbms_output.put_line(
        'user id: ' || p_user_id || 
        ' | total income: ' || v_income ||
        ' | frequency: ' || v_frequency);
end;


create or replace function get_category_info(p_category_name varchar2)
return varchar2
is
    v_description varchar2(200);
begin
    select description
    into v_description
    from categories
    where category_name = p_category_name
      and rownum = 1;  

    return v_description;
exception
    when no_data_found then
        return 'category not found';
end;

create or replace procedure show_category_info(p_category_name varchar2)
is
    v_description varchar2(200);
    v_type varchar2(50);
begin
    v_description := get_category_info(p_category_name);

    select category_type
    into v_type
    from categories
    where category_name = p_category_name
      and rownum = 1;

    dbms_output.put_line('--- category info for ' || p_category_name || ' ---');
    dbms_output.put_line(
        'category name: ' || p_category_name ||  -- Добавлен ||
        ' | type: ' || v_type ||                 -- Добавлен ||
        ' | description: ' || v_description
    );
exception
    when no_data_found then
        dbms_output.put_line('category not found: ' || p_category_name);
end;


-- collections

declare
  type t_rec is record (
    saving_id       number,
    suggested_topup number,
    confidence      varchar2(20),
    reason          varchar2(200)
  );
  type t_tab is table of t_rec;
  v_recs t_tab := t_tab();
  v_user_id constant number := 2;
  v_new_rec t_rec;
begin
  dbms_output.put_line('--- top-up recommendations for user ' || v_user_id || ' ---');
  for r in (
    select saving_id, nvl(current_amount,0) as current_amount, nvl(goal_amount,0) as goal_amount
    from savings
    where user_id = v_user_id
  ) loop
    v_new_rec.saving_id := r.saving_id;
    
    v_new_rec.suggested_topup := round(greatest(0, r.goal_amount - r.current_amount) * 0.20, 2);
    
    if v_new_rec.suggested_topup = 0 then
      v_new_rec.confidence := 'low';
      v_new_rec.reason := 'goal already reached or no gap';
    elsif r.current_amount / nullif(r.goal_amount,0) >= 0.75 then
      v_new_rec.confidence := 'high';
      v_new_rec.reason := 'close to goal';
    else
      v_new_rec.confidence := 'medium';
      v_new_rec.reason := 'suggest regular contributions';
    end if;

    v_recs.extend;
    v_recs(v_recs.count) := v_new_rec;
  end loop;

  for i in 1 .. v_recs.count loop
    dbms_output.put_line(
      'saving id: ' || v_recs(i).saving_id ||
      ' | topup: ' || v_recs(i).suggested_topup ||
      ' | conf: ' || v_recs(i).confidence ||
      ' | reason: ' || v_recs(i).reason
    );
  end loop;
end;
