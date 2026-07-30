-- ============================================================
-- PROJECT: Retail Demand Forecasting & Inventory Optimization
-- PHASE 2: SQL Database Design & Analysis
-- ============================================================
-- Step 1: Database & Table Creation
CREATE DATABASE IF NOT EXISTS retail_demand_forecasting;
USE retail_demand_forecasting;

CREATE TABLE suppliers(
    Supplier_ID     VARCHAR(10) PRIMARY KEY,
    Supplier_Name   VARCHAR(100) NOT NULL,
    Lead_Time       INT NOT NULL,
    Delivery_Rating DECIMAL(3,1)
);

CREATE TABLE products(
    Product_ID      VARCHAR(10) PRIMARY KEY,
    Product_Name    VARCHAR(150) NOT NULL,
    Category        VARCHAR(50),
    Subcategory     VARCHAR(50),
    Brand           VARCHAR(50),
    Cost_Price      DECIMAL(10,2),
    Selling_Price   DECIMAL(10,2),
    Supplier_ID     VARCHAR(10),
    FOREIGN KEY (Supplier_ID) REFERENCES suppliers(Supplier_ID)
);

CREATE TABLE warehouses(
    Warehouse_ID    VARCHAR(10) PRIMARY KEY,
    City            VARCHAR(50),
    State           VARCHAR(50),
    Capacity        INT
);

CREATE TABLE calendar(
    Date            DATE PRIMARY KEY,
    Month           VARCHAR(15),
    Quarter         VARCHAR(5),
    Week            INT,
    Year            INT,
    Holiday_Flag    TINYINT
);

CREATE TABLE inventory(
    Product_ID      VARCHAR(10),
    Warehouse_ID    VARCHAR(10),
    Current_Stock   INT,
    Reorder_Level   INT,
    Maximum_Stock   INT,
    Safety_Stock    INT,
    PRIMARY KEY (Product_ID, Warehouse_ID),
    FOREIGN KEY (Product_ID) REFERENCES products(Product_ID),
    FOREIGN KEY (Warehouse_ID) REFERENCES warehouses(Warehouse_ID)
);

CREATE TABLE sales(
    Order_ID        VARCHAR(15) PRIMARY KEY,
    Order_Date      DATE,
    Product_ID      VARCHAR(10),
    Customer_ID     VARCHAR(15),
    Store_ID        VARCHAR(15),
    Quantity_Sold   INT,
    Unit_Price      DECIMAL(10,2),
    Discount        DECIMAL(5,2),
    Sales           DECIMAL(12,2),
    Profit          DECIMAL(12,2),
    FOREIGN KEY (Product_ID) REFERENCES products(Product_ID),
    FOREIGN KEY (Order_Date) REFERENCES calendar(Date)
);

CREATE INDEX idx_sales_product ON sales(Product_ID);
CREATE INDEX idx_sales_date ON sales(Order_Date);
CREATE INDEX idx_sales_store ON sales(Store_ID);
CREATE INDEX idx_inventory_product ON inventory(Product_ID);

SELECT COUNT(*) FROM suppliers;   -- should be 15
SELECT COUNT(*) FROM products;    -- should be 200
SELECT COUNT(*) FROM warehouses;  -- should be 5
SELECT COUNT(*) FROM calendar;    -- should be 1096
SELECT COUNT(*) FROM inventory;   -- should be 1000
SELECT COUNT(*) FROM sales;       -- should be 200000

-- Step 3: Data Quality Validation
-- I validated data quality consistently across both the Python and SQL layers of my pipeline.
SELECT COUNT(*) AS invalid_product_refs
FROM sales s
LEFT JOIN products p ON s.Product_ID = p.Product_ID
WHERE p.Product_ID IS NULL;

-- Should match Python's (sales['Quantity_Sold'] <= 0).sum()
SELECT COUNT(*) AS negative_or_zero_qty FROM sales WHERE Quantity_Sold <= 0;

-- Should match Python's (sales['Discount'] > 1).sum()
SELECT COUNT(*) AS invalid_discount FROM sales WHERE Discount > 1 OR Discount < 0;

SELECT COUNT(*) AS duplicate_orders FROM (
    SELECT Order_ID, COUNT(*) c FROM sales GROUP BY Order_ID HAVING c > 1
) t;

-- Step 4: Business Insight Queries
-- ============================================================
-- A. SALES PERFORMANCE
-- ============================================================
-- A1. Monthly revenue & profit trend
SELECT 
    DATE_FORMAT(Order_Date, '%Y-%m') AS Month,
    SUM(Sales) AS Total_Sales,
    SUM(Profit) AS Total_Profit,
    ROUND(SUM(Profit) / SUM(Sales) * 100, 2) AS Profit_Margin_Pct
FROM sales
GROUP BY Month
ORDER BY Month;

-- A2. Year-over-Year growth
WITH yearly AS (
    SELECT YEAR(Order_Date) AS Yr, SUM(Sales) AS Total_Sales
    FROM sales
    GROUP BY YEAR(Order_Date)
)
SELECT 
    Yr,
    Total_Sales,
    LAG(Total_Sales) OVER (ORDER BY Yr) AS Prev_Year_Sales,
    ROUND((Total_Sales - LAG(Total_Sales) OVER (ORDER BY Yr)) 
        / LAG(Total_Sales) OVER (ORDER BY Yr) * 100, 2) AS YoY_Growth_Pct
FROM yearly;

-- A3. Top 10 products by revenue
SELECT *
FROM (
    SELECT 
        p.Product_Name,
        p.Category,
        SUM(s.Sales) AS Total_Revenue,
        RANK() OVER (ORDER BY SUM(s.Sales) DESC) AS Revenue_Rank
    FROM sales s
    JOIN products p ON s.Product_ID = p.Product_ID
    GROUP BY p.Product_Name, p.Category
) ranked
WHERE Revenue_Rank <= 10;

-- A4. Category contribution (Pareto analysis)
WITH cat_sales AS (
    SELECT p.Category, SUM(s.Sales) AS Category_Sales
    FROM sales s JOIN products p ON s.Product_ID = p.Product_ID
    GROUP BY p.Category
)
SELECT 
    Category,
    Category_Sales,
    ROUND(Category_Sales / SUM(Category_Sales) OVER () * 100, 2) AS Pct_of_Total,
    ROUND(SUM(Category_Sales) OVER (ORDER BY Category_Sales DESC) 
        / SUM(Category_Sales) OVER () * 100, 2) AS Cumulative_Pct
FROM cat_sales
ORDER BY Category_Sales DESC;

-- A5. Store performance
SELECT 
    Store_ID,
    SUM(Sales) AS Total_Sales,
    SUM(Profit) AS Total_Profit,
    COUNT(DISTINCT Order_ID) AS Total_Orders,
    ROUND(SUM(Sales) / COUNT(DISTINCT Order_ID), 2) AS Avg_Order_Value
FROM sales
GROUP BY Store_ID
ORDER BY Total_Sales DESC;

-- A6. Holiday impact
SELECT 
    c.Holiday_Flag,
    COUNT(s.Order_ID) AS Total_Orders,
    SUM(s.Sales) AS Total_Sales,
    ROUND(AVG(s.Sales), 2) AS Avg_Sale_Value
FROM sales s
JOIN calendar c ON s.Order_Date = c.Date
GROUP BY c.Holiday_Flag;

-- A7. Day-of-week seasonality
SELECT 
    DAYNAME(Order_Date) AS Day_of_Week,
    SUM(Sales) AS Total_Sales,
    ROUND(AVG(Sales), 2) AS Avg_Sales_Per_Order
FROM sales
GROUP BY Day_of_Week
ORDER BY FIELD(Day_of_Week,'Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday');

-- ============================================================
-- B. DEMAND FORECASTING SUPPORT
-- ============================================================
-- B1. Product-level monthly demand
SELECT 
    p.Product_ID,
    p.Product_Name,
    DATE_FORMAT(s.Order_Date, '%Y-%m') AS Month,
    SUM(s.Quantity_Sold) AS Monthly_Demand
FROM sales s
JOIN products p ON s.Product_ID = p.Product_ID
GROUP BY p.Product_ID, p.Product_Name, Month
ORDER BY p.Product_ID, Month;

-- B2. 3-month moving average demand
WITH monthly_demand AS (
    SELECT 
        Product_ID,
        DATE_FORMAT(Order_Date, '%Y-%m') AS Month,
        SUM(Quantity_Sold) AS Total_Qty
    FROM sales
    GROUP BY Product_ID, Month
)
SELECT 
    Product_ID,
    Month,
    Total_Qty,
    ROUND(AVG(Total_Qty) OVER (
        PARTITION BY Product_ID 
        ORDER BY Month 
        ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
    ), 2) AS Moving_Avg_3M
FROM monthly_demand
ORDER BY Product_ID, Month;

-- B3. Demand volatility (Coefficient of Variation)
WITH monthly_demand AS (
    SELECT Product_ID, DATE_FORMAT(Order_Date, '%Y-%m') AS Month, SUM(Quantity_Sold) AS Qty
    FROM sales GROUP BY Product_ID, Month
)
SELECT 
    Product_ID,
    ROUND(AVG(Qty), 2) AS Avg_Monthly_Demand,
    ROUND(STDDEV(Qty), 2) AS Demand_StdDev,
    ROUND(STDDEV(Qty) / AVG(Qty), 2) AS Coefficient_of_Variation
FROM monthly_demand
GROUP BY Product_ID
HAVING AVG(Qty) > 0
ORDER BY Coefficient_of_Variation DESC;

-- ============================================================
-- C. INVENTORY OPTIMIZATION
-- ============================================================
-- C1. Products below reorder level
SELECT 
    i.Product_ID,
    p.Product_Name,
    i.Warehouse_ID,
    w.City,
    i.Current_Stock,
    i.Reorder_Level,
    i.Safety_Stock,
    (i.Reorder_Level - i.Current_Stock) AS Units_Below_Reorder
FROM inventory i
JOIN products p ON i.Product_ID = p.Product_ID
JOIN warehouses w ON i.Warehouse_ID = w.Warehouse_ID
WHERE i.Current_Stock <= i.Reorder_Level
ORDER BY Units_Below_Reorder DESC;

-- C2. Days of stock remaining
WITH avg_daily_demand AS (
    SELECT 
        Product_ID,
        SUM(Quantity_Sold) / 90 AS Avg_Daily_Demand
    FROM sales
    WHERE Order_Date >= (SELECT MAX(Order_Date) FROM sales) - INTERVAL 90 DAY
    GROUP BY Product_ID
)
SELECT 
    i.Product_ID,
    p.Product_Name,
    i.Warehouse_ID,
    i.Current_Stock,
    ROUND(a.Avg_Daily_Demand, 2) AS Avg_Daily_Demand,
    ROUND(i.Current_Stock / NULLIF(a.Avg_Daily_Demand, 0), 1) AS Days_of_Stock_Remaining
FROM inventory i
JOIN products p ON i.Product_ID = p.Product_ID
LEFT JOIN avg_daily_demand a ON i.Product_ID = a.Product_ID
ORDER BY Days_of_Stock_Remaining ASC;

-- C3. Warehouse utilization %
SELECT 
    w.Warehouse_ID,
    w.City,
    w.Capacity,
    SUM(i.Current_Stock) AS Total_Stock_Held,
    ROUND(SUM(i.Current_Stock) / w.Capacity * 100, 2) AS Utilization_Pct
FROM inventory i
JOIN warehouses w ON i.Warehouse_ID = w.Warehouse_ID
GROUP BY w.Warehouse_ID, w.City, w.Capacity
ORDER BY Utilization_Pct DESC;

-- C4. Overstock risk
SELECT 
    i.Product_ID,
    p.Product_Name,
    i.Warehouse_ID,
    i.Current_Stock,
    i.Maximum_Stock,
    ROUND(i.Current_Stock / i.Maximum_Stock * 100, 2) AS Pct_of_Max_Capacity
FROM inventory i
JOIN products p ON i.Product_ID = p.Product_ID
WHERE i.Current_Stock >= 0.9 * i.Maximum_Stock
ORDER BY Pct_of_Max_Capacity DESC;

-- ============================================================
-- D. SUPPLIER PERFORMANCE
-- ============================================================
-- D1. Supplier reliability vs product profitability
SELECT 
    sup.Supplier_ID,
    sup.Supplier_Name,
    sup.Lead_Time,
    sup.Delivery_Rating,
    COUNT(DISTINCT p.Product_ID) AS Products_Supplied,
    ROUND(AVG(p.Selling_Price - p.Cost_Price), 2) AS Avg_Margin_Per_Unit
FROM suppliers sup
JOIN products p ON sup.Supplier_ID = p.Supplier_ID
GROUP BY sup.Supplier_ID, sup.Supplier_Name, sup.Lead_Time, sup.Delivery_Rating
ORDER BY sup.Delivery_Rating DESC;

-- D2. Suppliers linked to frequent stockouts
SELECT 
    sup.Supplier_Name,
    sup.Lead_Time,
    COUNT(*) AS Low_Stock_Product_Count
FROM inventory i
JOIN products p ON i.Product_ID = p.Product_ID
JOIN suppliers sup ON p.Supplier_ID = sup.Supplier_ID
WHERE i.Current_Stock <= i.Reorder_Level
GROUP BY sup.Supplier_Name, sup.Lead_Time
ORDER BY Low_Stock_Product_Count DESC;

-- ============================================================
-- E. CUSTOMER ANALYSIS
-- ============================================================
-- E1. Top customers by revenue
SELECT 
    Customer_ID,
    COUNT(DISTINCT Order_ID) AS Total_Orders,
    SUM(Sales) AS Total_Spend,
    ROUND(AVG(Sales), 2) AS Avg_Order_Value
FROM sales
GROUP BY Customer_ID
ORDER BY Total_Spend DESC
LIMIT 20;

-- E2. Purchase recency
SELECT 
    Customer_ID,
    MAX(Order_Date) AS Last_Purchase_Date,
    DATEDIFF((SELECT MAX(Order_Date) FROM sales), MAX(Order_Date)) AS Days_Since_Last_Purchase
FROM sales
GROUP BY Customer_ID
ORDER BY Days_Since_Last_Purchase DESC
LIMIT 20;

SELECT 'suppliers' AS table_name, COUNT(*) AS row_count FROM suppliers
UNION ALL
SELECT 'products', COUNT(*) FROM products
UNION ALL
SELECT 'warehouses', COUNT(*) FROM warehouses
UNION ALL
SELECT 'calendar', COUNT(*) FROM calendar
UNION ALL
SELECT 'inventory', COUNT(*) FROM inventory
UNION ALL
SELECT 'sales', COUNT(*) FROM sales;